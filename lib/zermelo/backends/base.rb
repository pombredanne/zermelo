require 'active_support/concern'

require 'zermelo/locks/no_lock'

module Zermelo

  module Backends

    module Base

      extend ActiveSupport::Concern

      def escape_key_name(name)
        name.gsub(/%/, '%%').gsub(/ /, '%20').gsub(/:/, '%3A')
      end

      def unescape_key_name(name)
        name.gsub(/%3A/, ':').gsub(/%20/, ' ').gsub(/%%/, '%')
      end

      def index_keys(type, value)
        return ["null", "null"] if value.nil?

        case type
        when :string
          ["string", escape_key_name(value)]
        when :integer
          ["integer", escape_key_name(value.to_s)]
        when :float
          ["float", escape_key_name(value.to_s)]
        when :timestamp
          case value
          when Integer
            ["timestamp", escape_key_name(value.to_s)]
          when Time, DateTime
            ["timestamp", escape_key_name(value.to_i.to_s)]
          end
        when :boolean
          case value
          when TrueClass
            ["boolean", "true"]
          when FalseClass
            ["boolean", "false"]
          end
        end
      end

      # for hashes, lists, sets
      def add(key, value)
        change(:add, key, value)
      end

      def delete(key, value)
        change(:delete, key, value)
      end

      def move(key, value, key_to)
        change(:move, key, value, key_to)
      end

      def clear(key)
        change(:clear, key)
      end

      # works for both simple and complex types (i.e. strings, numbers, booleans,
      #  hashes, lists, sets)
      def set(key, value)
        change(:set, key, value)
      end

      def purge(key)
        change(:purge, key)
      end

      def get(attr_key)
        get_multiple(attr_key)[attr_key.klass][attr_key.id][attr_key.name.to_s]
      end

      def lock(*klasses, &block)
        ret = nil
        # doesn't handle re-entrant case for influxdb, which has no locking yet
        locking = Thread.current[:zermelo_locking]
        if locking.nil?
          lock_proc = proc do
            begin
              Thread.current[:zermelo_locking] = klasses
              ret = block.call
            ensure
              Thread.current[:zermelo_locking] = nil
            end
          end

          lock_klass = case self
          when Zermelo::Backends::RedisBackend
            Zermelo::Locks::RedisLock
          else
            Zermelo::Locks::NoLock
          end

          lock_klass.new.lock(*klasses, &lock_proc)
        else
          # accepts any subset of 'locking'
          unless (klasses - locking).empty?
            raise "Currently locking #{locking.map(&:name)}, cannot lock different set #{klasses.map(&:name)}"
          end
          ret = block.call
        end
        ret
      end

    end

  end

end