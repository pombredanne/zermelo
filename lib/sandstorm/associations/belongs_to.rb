# The other side of a has_one, has_many, or has_sorted_set association

module Sandstorm
  module Associations
    class BelongsTo

      # NB a single instance of this class doesn't need to care about the hash
      # used for storage, that should be done in the save method of the parent

      def initialize(parent, name)
        @parent = parent
        @name   = name

        @backend = parent.send(:backend)

        @record_ids_key = Sandstorm::Records::Key.new(
          :klass  => parent.class.send(:class_key),
          :id     => parent.id,
          :name   => 'belongs_to',
          :type   => :hash,
          :object => :association
        )

        parent.class.send(:with_association_data, name.to_sym) do |data|
          @associated_class = data.data_klass
          @inverse          = data.inverse
          @callbacks        = data.callbacks
        end

        raise ':inverse_of must be set' if @inverse.nil?
        @inverse_key = "#{name}_id"
      end

      def value=(record)
        if record.nil?
          @parent.class.lock(@associated_class) do
            r = @associated_class.send(:load, @backend.get(@record_ids_key)[@inverse_key.to_s])
            br = @callbacks[:before_remove]
            @parent.send(br, r) if !br.nil? && @parent.respond_to?(br)
            new_txn = @backend.begin_transaction
            @backend.delete(@record_ids_key, @inverse_key)
            @backend.commit_transaction if new_txn
            ar = @callbacks[:after_remove]
            @parent.send(ar, r) if !ar.nil? && @parent.respond_to?(ar)
          end
        else
          raise 'Invalid record class' unless record.is_a?(@associated_class)
          raise 'Record must have been saved' unless record.persisted?
          @parent.class.lock(@associated_class) do
            ba = @callbacks[:before_add]
            @parent.send(ba, record) if !ba.nil? && @parent.respond_to?(ba)
            new_txn = @backend.begin_transaction
            @backend.add(@record_ids_key, @inverse_key => record.id)
            @backend.commit_transaction if new_txn
            aa = @callbacks[:after_add]
            @parent.send(aa, record) if !aa.nil? && @parent.respond_to?(aa)
          end
        end
      end

      def value
        @parent.class.lock(@associated_class) do
          # FIXME uses hgetall, need separate getter for hash/list/set
          if id = @backend.get(@record_ids_key)[@inverse_key.to_s]
          # if id = @backend.get_hash_value(@record_ids_key, @inverse_key.to_s)
            @associated_class.send(:load, id)
          else
            nil
          end
        end
      end

      private

      # on_remove already runs inside a lock & transaction
      def on_remove
        unless value.nil?
          assoc = value.send("#{@inverse}_proxy".to_sym)
          if assoc.respond_to?(:delete)
            assoc.send(:delete, @parent)
          elsif assoc.respond_to?(:value=)
            assoc.send(:value=, nil)
          end
        end
        @backend.clear(@record_ids_key)
      end

      def self.associated_ids_for(backend, class_key, name, inversed, *these_ids)
        these_ids.each_with_object({}) do |this_id, memo|
          key = Sandstorm::Records::Key.new(
            :klass  => class_key,
            :id     => this_id,
            :name   => 'belongs_to',
            :type   => :hash,
            :object => :association
          )

          assoc_id = backend.get(key)["#{name}_id"]
          # assoc_id = backend.get_hash_value(key, "#{name}_id")

          if inversed
            memo[assoc_id] ||= []
            memo[assoc_id] << this_id
          else
            memo[this_id] = assoc_id
          end
        end
      end

    end
  end
end