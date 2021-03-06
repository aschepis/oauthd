Q = require 'q'
async = require 'async'


module.exports = (env) ->

	class Entity
		@prefix: ''
		@incr: ''
		@indexes: []
		@findById: (id) ->
			defer = Q.defer()
			lapin = new @(id)
			lapin.load()
				.then () ->
					defer.resolve lapin
				.fail (e) ->
					defer.reject e
			defer.promise
		@findByIndex: (field, index) ->
			defer = Q.defer()
			# looking for id
			env.data.redis.hget @indexes[field], index, (err, id) =>
				return defer.reject err if err
				entity = new @(id)
				entity.load()
					.then () ->
						defer.resolve entity
					.fail (e) ->
						defer.reject e
			defer.promise
		@onCreate: (entity) ->
			# creation additional operations
		@onUpdate: (entity) ->
			# update additional operations
		@onSave: (entity) ->
			# save additional operations (always called)
		@onRemove: (entity) ->
			# removal additional operations
		@onCreateAsync: (entity, done) ->
			# async creation additional operations
			done()
		@onUpdateAsync: (entity, done) ->
			# async update additional operations
			done()
		@onSaveAsync: (entity, done) ->
			# async save additional operations (always called)
			done()
		@onRemoveAsync: (entity, done) ->
			# asunc removal additional operations
			done()
		id: 0 # represents the entity in db
		oldIndexesValues: {}
		props: {} # the entity's properties
		prefix: () -> # the prefix of the entity, e.g. user:23:
			@constructor.prefix + ':' + @id + ':'
		constructor: (id) ->
			@id = id
		keys: () ->
			defer = Q.defer()
			keys = {}
			env.data.redis.keys @prefix() + '*', (e, result) ->
				if e
					defer.reject e
				else
					defer.resolve result

			defer.promise
		typedKeys: () ->
			defer = Q.defer()
			keys = {}
			env.data.redis.keys @prefix() + '*', (e, result) =>
				async.eachSeries result
				, (key, next) =>
					env.data.redis.type key, (e, type) =>
						defer.reject(e) if e
						keyname = key.replace @prefix(), ''
						keys[keyname] = type
						next()
				, (e, final_result) ->
					if e
						defer.reject(e)
					else
						defer.resolve(keys)

			defer.promise

		getAll: () ->
			defer = Q.defer()

			@typedKeys()
				.then (keys) =>
					cmds = []

					for key, type of keys
						if type == 'hash'
							cmds.push ['hgetall', @prefix() + key]
						if type == 'string'
							cmds.push ['get', @prefix() + key]
						if type == 'set'
							cmds.push ['smembers', @prefix() + key]

					env.data.redis.multi(cmds).exec (err, fields) ->
						object = {}
						keys_array = Object.keys keys
						for k, v of fields
							object[keys_array[k]] = v
						defer.resolve(object)
				.fail (e) ->
					defer.reject e

			defer.promise
		load: () ->
			defer = Q.defer()
			@getAll()
				.then (data) =>
					if Object.keys(data).length > 0
						@props = data
						defer.resolve(data)
					else
						defer.reject new Error('Data not found')
				.fail (e) ->
					defer.reject(e)

			defer.promise

		# accepted values for opts:
		# - overwrite: boolean - overwrite values, default true
		# - del_unset - delete not set values, default false
		# - ttl: time to live for entry, in seconds (from creation or update time)
		save: (opts) ->
			opts = opts || {}
			overwrite = opts.overwrite
			overwrite ?= true

			delete_unknown_keys = opts.del_unset
			delete_unknown_keys ?= false
			defer = Q.defer()

			# hat function that actually saves
			_save = (done) =>
				multi = env.data.redis.multi()

				@keys()
					.then (keys) =>
						if delete_unknown_keys
							prefixedProps = []
							for key in Object.keys(@props)
								prefixedProps.push @prefix() + key
							for key in keys
								if key not in prefixedProps
									multi.del key
						async.waterfall [
							# Managing indexes, removing unused values, and adding new values
							(cb) =>
								index_keys = Object.keys(@constructor.indexes)
								async.eachSeries index_keys, (key, ccb) =>
									index_key = key
									index_field = @constructor.indexes[key]
									env.data.redis.get @prefix() + index_key, (err, value) =>
										if not err and @props[index_key]? and value? != @props[index_key]
											multi.hdel index_field, value
											multi.hset index_field, @props[index_key], @id
										if not value
											multi.set @prefix() + index_key, @props[index_key]
										ccb()
								, () =>
									cb()
							# Saving normal keys
							(cb) =>
								for key, value of @props
									# check if key is an index
									index_field = @constructor.indexes[key]
									if index_field?
										if @oldIndexesValues[key]? and @oldIndexesValues[key] != value
											multi.hdel index_field, @oldIndexesValues[key]
									if typeof value == 'string' or typeof value == 'number'
										multi.set @prefix() + key, value
									else if typeof value == 'object' and Array.isArray(value)
										multi.del @prefix() + key
										for k, v of value
											multi.sadd @prefix() + key, v
									else if	value? and typeof value == 'object'
										if overwrite
											multi.del @prefix() + key
										multi.hmset @prefix() + key, value
									else
										# TODO (value instanceof Boolean || typeof value == 'boolean')
										console.log "not saved: type not found"
									if opts.ttl?
										multi.expire @prefix() + key, opts.ttl

									cb()
						], () =>
							# Actual execution of the db access
							multi.exec (e, res) =>
								return done e if e
								done()
					.fail (e) =>
						return done e if e

			# checks if new entity or not. If no id found, increments ids
			if not @id?
				env.data.redis.incr @constructor.incr, (e, id) =>
					@id = id
					_save (e) =>
						return defer.reject e if e
						@constructor.onCreate @
						@constructor.onSave @
						@constructor.onCreateAsync @, (e) =>
							return defer.reject e if e
							@constructor.onSaveAsync @, (e) =>
								return defer.reject e if e
								defer.resolve()
			else
				_save (e) =>
					return defer.reject e if e
					@constructor.onUpdate @
					@constructor.onSave @
					@constructor.onUpdateAsync @, (e) =>
						return defer.reject e if e
						@constructor.onSaveAsync @, (e) =>
							return defer.reject e if e
							defer.resolve()


			defer.promise
		remove: () ->
			defer = Q.defer()
			multi = env.data.redis.multi()

			async.waterfall [
				# first delete indexes
				(next) =>
					index_keys = Object.keys @constructor.indexes
					async.eachSeries index_keys, (key, next2) =>
						env.data.redis.get @prefix() + key, (err, index_value) =>
							if not err? and index_value?
								multi.hdel @constructor.indexes[key], index_value
							next2()
					, () =>
						next()
				# then delete normal keys
				(next) =>
					@keys()
						.then (keys) =>
							for key in keys
								multi.del key
							multi.exec (e) =>
								return defer.reject e if e
								@constructor.onRemoveAsync @, (e) =>
									return defer.reject e if e
									defer.resolve()
									next()
						.fail (e) =>
							defer.reject e
							next()
			]
			defer.promise

	Entity
