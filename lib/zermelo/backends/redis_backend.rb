require 'zermelo/backends/base'

require 'zermelo/filters/redis_filter'
require 'zermelo/locks/redis_lock'

module Zermelo

  module Backends

    class RedisBackend

      include Zermelo::Backends::Base

      def generate_lock
        Zermelo::Locks::RedisLock.new
      end

      def filter(ids_key, record)
        Zermelo::Filters::RedisFilter.new(self, ids_key, record)
      end

      def get_multiple(*attr_keys)
        attr_keys.inject({}) do |memo, attr_key|
          redis_attr_key = key_to_redis_key(attr_key)

          memo[attr_key.klass] ||= {}
          memo[attr_key.klass][attr_key.id] ||= {}
          memo[attr_key.klass][attr_key.id][attr_key.name.to_s] = if Zermelo::COLLECTION_TYPES.has_key?(attr_key.type)

            case attr_key.type
            when :list
              if attr_key.accessor.nil?
                Zermelo.redis.lrange(redis_attr_key, 0, -1)
              else

              end
            when :set
              if attr_key.accessor.nil?
                Set.new( Zermelo.redis.smembers(redis_attr_key) )
              else

              end
            when :hash
              if attr_key.accessor.nil?
                Zermelo.redis.hgetall(redis_attr_key)
              else

              end
            when :sorted_set
              # TODO should this be something that preserves order?
              if attr_key.accessor.nil?
                Set.new( Zermelo.redis.zrange(redis_attr_key, 0, -1) )
              else

              end
            end

          else
            value = Zermelo.redis.hget(redis_attr_key, attr_key.name.to_s)

            if value.nil?
              nil
            else
              case attr_key.type
              when :string
                value.to_s
              when :integer
                value.to_i
              when :float
                value.to_f
              when :timestamp
                Time.at(value.to_f)
              when :boolean
                case value
                when TrueClass
                  true
                when FalseClass
                  false
                when String
                  'true'.eql?(value.downcase)
                else
                  nil
                end
              end
            end
          end
          memo
        end
      end

      def exists?(key)
        Zermelo.redis.exists(key_to_redis_key(key))
      end

      def include?(key, id)
        case key.type
        when :set
          Zermelo.redis.sismember(key_to_redis_key(key), id)
        else
          raise "Not implemented"
        end
      end

      def begin_transaction
        return false unless @transaction_redis.nil?
        @transaction_redis = Zermelo.redis
        @transaction_redis.multi
        @changes = []
        true
      end

      def commit_transaction
        return false if @transaction_redis.nil?
        apply_changes(@changes)
        @transaction_redis.exec
        @transaction_redis = nil
        @changes = []
        true
      end

      def abort_transaction
        return false if @transaction_redis.nil?
        @transaction_redis.discard
        @transaction_redis = nil
        @changes = []
        true
      end

      # used by redis_filter
      def key_to_redis_key(key)
        obj = case key.object
        when :attribute
          'attrs'
        when :association
          'assocs'
        when :index
          'indices'
        end

        name = Zermelo::COLLECTION_TYPES.has_key?(key.type) ? ":#{key.name}" : ''

        "#{key.klass}:#{key.id.nil? ? '' : key.id}:#{obj}#{name}"
      end

      private

      def change(op, key, value = nil, key_to = nil)
        ch = [op, key, value, key_to]
        if @in_transaction
          @changes << ch
        else
          apply_changes([ch])
        end
      end

      def apply_changes(changes)
        simple_attrs  = {}

        purges = []

        changes.each do |ch|
          op     = ch[0]
          key    = ch[1]
          value  = ch[2]
          key_to = ch[3]

          # TODO check that collection types handle nil value for whole thing
          if Zermelo::COLLECTION_TYPES.has_key?(key.type)

            complex_attr_key = key_to_redis_key(key)

            case op
            when :add, :set
              case key.type
              when :list
                Zermelo.redis.del(complex_attr_key) if :set.eql?(op)
                Zermelo.redis.rpush(complex_attr_key, value)
              when :set
                Zermelo.redis.del(complex_attr_key) if :set.eql?(op)
                case value
                when Set
                  Zermelo.redis.sadd(complex_attr_key, value.to_a) unless value.empty?
                when Array
                  Zermelo.redis.sadd(complex_attr_key, value) unless value.empty?
                else
                  Zermelo.redis.sadd(complex_attr_key, value)
                end
              when :hash
                Zermelo.redis.del(complex_attr_key) if :set.eql?(op)
                unless value.nil?
                  kv = value.inject([]) do |memo, (k, v)|
                    memo += [k, v]
                    memo
                  end
                  Zermelo.redis.hmset(complex_attr_key, *kv)
                end
              when :sorted_set
                Zermelo.redis.zadd(complex_attr_key, *value)
              end
            when :move
              case key.type
              when :set
                Zermelo.redis.smove(complex_attr_key, key_to_redis_key(key_to), value)
              when :list
                # TODO would do via sort 'nosort', except for
                # https://github.com/antirez/redis/issues/2079 -- instead,
                # copy the workaround from redis_filter.rb
                raise "Not yet implemented"
              when :hash
                values = value.to_a.flatten
                Zermelo.redis.hdel(complex_attr_key, values)
                Zermelo.redis.hset(key_to_redis_key(key_to), *values)
              when :sorted_set
                raise "Not yet implemented"
              end
            when :delete
              case key.type
              when :list
                Zermelo.redis.lrem(complex_attr_key, value, 0)
              when :set
                Zermelo.redis.srem(complex_attr_key, value)
              when :hash
                Zermelo.redis.hdel(complex_attr_key, value)
              when :sorted_set
                Zermelo.redis.zrem(complex_attr_key, value)
              end
            when :clear
              Zermelo.redis.del(complex_attr_key)
            end

          elsif :purge.eql?(op)
            # TODO get keys for all assocs & indices, purge them too
            purges << ["#{key.klass}:#{key.id}:attrs"]
          else
            simple_attr_key = key_to_redis_key(key)
            simple_attrs[simple_attr_key] ||= {}

            case op
            when :set
              simple_attrs[simple_attr_key][key.name] = if value.nil?
                nil
              else
                case key.type
                when :string, :integer
                  value.to_s
                when :float, :timestamp
                  value.to_f
                when :boolean
                  (!!value).to_s
                end
              end
            when :clear
              simple_attrs[simple_attr_key][key.name] = nil
            end
          end
        end

        unless simple_attrs.empty?
          simple_attrs.each_pair do |simple_attr_key, values|
            hset = []
            hdel = []
            values.each_pair do |k, v|
              if v.nil?
                hdel << k
              else
                hset += [k, v]
              end
            end
            Zermelo.redis.hmset(simple_attr_key, *hset) if hset.present?
            Zermelo.redis.hdel(simple_attr_key, hdel) if hdel.present?
          end
        end

        purges.each {|purge_key | Zermelo.redis.del(purge_key) }
      end

    end

  end

end