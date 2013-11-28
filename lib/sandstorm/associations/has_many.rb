require 'forwardable'

require 'sandstorm'
require 'sandstorm/filter'
require 'sandstorm/redis_key'

module Sandstorm
  module Associations
    class HasMany

      extend Forwardable

      def_delegators :filter, :intersect, :union, :diff,
                       :count, :empty?, :exists?, :find_by_id,
                       :all, :each, :collect, :select, :find_all, :reject,
                       :ids

      def initialize(parent, name, options = {})
        @record_ids = Sandstorm::RedisKey.new("#{parent.record_key}:#{name}_ids", :set)
        @name = name
        @parent = parent

        # TODO trap possible constantize error
        @associated_class = (options[:class_name] || name.classify).constantize

        @inverse = @associated_class.send(:inverse_of, name, @parent.class)
      end

      def <<(record)
        add(record)
        self  # for << 'a' << 'b'
      end

      def add(*records)
        raise 'Invalid record class' if records.any? {|r| !r.is_a?(@associated_class)}
        records.each do |record|
          raise "Record must have been saved" unless record.persisted?
          unless @inverse.nil?

            # !!!
            @associated_class.send(:load, record.id).send("#{@inverse}=", @parent)

          end
        end
        Sandstorm.redis.sadd(@record_ids.key, records.map(&:id))
      end

      # TODO support dependent delete, for now just deletes the association
      def delete(*records)
        raise 'Invalid record class' if records.any? {|r| !r.is_a?(@associated_class)}
        unless @inverse.nil?
          records.each do |record|
            raise "Record must have been saved" unless record.persisted?

            # !!!
            @associated_class.send(:load, record.id).send("#{@inverse}=", nil)

          end
        end
        Sandstorm.redis.srem(@record_ids.key, records.map(&:id))
      end

      private

      # associated will be a belongs_to
      def on_remove
        unless @inverse.nil?
          Sandstorm.redis.smembers(@record_ids.key).each do |record_id|
            @associated_class.send(:load, record_id).send("#{@inverse}=", nil)
          end
        end
        Sandstorm.redis.del(@record_ids.key)
      end

      # creates a new filter class each time it's called, to store the
      # state for this particular filter chain
      def filter
        Sandstorm::Filter.new(@record_ids, @associated_class)
      end

    end
  end
end