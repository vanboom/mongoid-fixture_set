require 'mongoid/fixture_set/errors'
require 'mongoid/fixture_set/fixture'
require 'mongoid/fixture_set/file'
require 'mongoid/fixture_set/class_cache'
require 'mongoid/fixture_set/test_helper'

module Mongoid
  class FixtureSet
    @@cached_fixtures = Hash.new

    cattr_accessor :all_loaded_fixtures
    self.all_loaded_fixtures = {}

    class << self
      def context_class
        @context_class ||= Class.new
      end

      def cached_fixtures(keys_to_fetch = nil)
        if keys_to_fetch
          @@cached_fixtures.values_at(*keys_to_fetch)
        else
          @@cached_fixtures.values
        end
      end

      def reset_cache
        @@cached_fixtures.clear
      end

      def cache_empty?
        @@cached_fixtures.empty?
      end

      def fixture_is_cached?(name)
        @@cached_fixtures[name]
      end

      def cache_fixtures(fixtures_map)
        @@cached_fixtures.update(fixtures_map)
      end

      def default_fixture_model_name(fixture_set_name)
        fixture_set_name.singularize.camelize
      end

      def update_all_loaded_fixtures(fixtures_map)
        all_loaded_fixtures.update(fixtures_map)
      end

      def create_fixtures(fixtures_directory, fixture_set_names, class_names = {})
        fixture_set_names = Array(fixture_set_names).map(&:to_s)
        class_names = ClassCache.new(class_names)

        files_to_read = fixture_set_names.reject { |fs_name|
          fixture_is_cached?(fs_name)
        }

        if files_to_read.empty?
          return cached_fixtures(fixture_set_names)
        end

        fixtures_map = {}
        fixture_sets = files_to_read.map do |fs_name|
          klass = class_names[fs_name]
          fixtures_map[fs_name] = Mongoid::FixtureSet.new(
                                      fs_name,
                                      klass,
                                      ::File.join(fixtures_directory, fs_name))
        end

        update_all_loaded_fixtures fixtures_map

        fixture_sets.each do |fs|
          fs.collection_documents.each do |model, documents|
            model = class_names[model]
            if model
              documents.each do |attributes|
                create_or_update_document(model, attributes)
              end
            end
          end
        end

        cache_fixtures(fixtures_map)

        return cached_fixtures(fixture_set_names)
      end

      def create_or_update_document(model, attributes)
        model = model.constantize if model.is_a? String

        document = find_or_new_document(model, attributes['__fixture_name'])
        update_document(document, attributes)
      end

      def update_document(document, attributes)
        attributes.delete('_id') if document.attributes.has_key?('_id')

        keys = (attributes.keys + document.attributes.keys).uniq
        keys.each do |key|
          # detect nested attributes
          if attributes[key].is_a?(Array) || document[key].is_a?(Array)
            # DVB: strange handling here
            document[key] = (Array(attributes[key]) + Array(document[key]))
          elsif attributes[key]
            document[key] = attributes[key] || document[key]
          end
        end
        sanitize_new_embedded_documents(document)
        document.save(validate: false)
        return document
      end

      def sanitize_new_embedded_documents(document, is_new = false)
        document.relations.each do |name, relation|
          case relation.class.to_s
          when "Mongoid::Association::Embedded::EmbedsOne"
            if (document.changes[name] && !document.changes[name][1].nil?) ||
              (is_new && document[name])

              embedded_document_set_default_values(document.public_send(relation.name), document[name])
            end
          when "Mongoid::Association::Embedded::EmbedsMany"
            if (document.changes[name] && !document.changes[name][1].nil?) ||
              (is_new && document[name])

              embeddeds = document.public_send(relation.name)
              embeddeds.each_with_index do |embedded, i|
                embedded_document_set_default_values(embedded, document[name][i])
              end
            end
          when "Mongoid::Association::Referenced::BelongsTo"
            if is_new && document.attributes[name]
              value = document.attributes.delete(name)
              if value.is_a?(Hash)
                raise Mongoid::FixtureSet::FixtureError.new "Unable to create nested document inside an embedded document"
              end
              doc = find_or_new_document(relation.class_name, value)
              document.attributes[relation.foreign_key] = doc.id
            end
          end
        end
      end

      def embedded_document_set_default_values(document, attributes)
        sanitize_new_embedded_documents(document, true)
        attributes.delete('_id')
        document.fields.select do |k, v|
          k != '_id' && v.default_val != nil && attributes[k] == document[k]
        end.each do |k, v|
          attributes.delete(k)
        end
      end

      def find_or_new_document(model, fixture_name)
        model = model.constantize if model.is_a? String
        document = model.where('__fixture_name' => fixture_name).first
        if document.nil?
          # force the object ID to be based on the fixture name
          document = model.new(id: fixture_object_id(fixture_name).to_s)
          document['__fixture_name'] = fixture_name
          ##
          # DVB:  do not save the document here without attributes because
          # this inhibits the use of attr_readonly
          # HUH?  This is causing belongs_to relations not to preload - REMOVE IT 12/9/2024
          document.save(validate: false)
        end
        return document
      end
    end

    attr_reader :name, :path, :model_class, :class_name
    attr_reader :fixtures

    def initialize(name, class_name, path)
      @name = name
      @path = path

      if class_name.is_a?(Class)
        @model_class = class_name
      elsif class_name
        @model_class = class_name.safe_constantize
      end

      @class_name = @model_class.respond_to?(:name) ?
        @model_class.name :
        self.class.default_fixture_model_name(name)

      @fixtures = read_fixture_files
    end

    def [](x)
      fixtures[x]
    end

    def collection_documents
      # allow a standard key to be used for doing defaults in YAML
      fixtures.delete('DEFAULTS')

      # track any join collection we need to insert later
      documents = Hash.new

      documents[class_name] = fixtures.map do |label, fixture|
        unmarshall_fixture(label, fixture, model_class)
      end
      return documents
    end

    private
    def unmarshall_fixture(label, attributes, model_class)
      model_class = model_class.constantize if model_class.is_a? String
      attributes = attributes.to_hash

      if label
        attributes['__fixture_name'] = label

        # interpolate the fixture label
        attributes.each do |key, value|
          attributes[key] = value.gsub("$LABEL", label) if value.is_a?(String)
        end
      end

      return attributes if model_class.nil?

      if !attributes.has_key?('_id')
        if label
          document = self.class.find_or_new_document(model_class, label)
        else
          document = model_class.new
        end
        attributes['_id'] = document.id
      end

      set_attributes_timestamps(model_class, attributes)

      model_class.relations.each_value do |relation|
        #next unless relation.respond_to? :macro
        case relation.class.to_s
        when "Mongoid::Association::Referenced::BelongsTo"
          unmarshall_belongs_to(model_class, attributes, relation)
        when "Mongoid::Association::Referenced::HasMany"
          unmarshall_has_many(model_class, attributes, relation)
        when "Mongoid::Association::Referenced::HasAndBelongsToMany"
          unmarshall_has_and_belongs_to_many(model_class, attributes, relation)
        end
      end

      return attributes
    end

    def unmarshall_belongs_to(model_class, attributes, relation)
      value = attributes.delete(relation.name.to_s)
      return if value.nil?

      if value.is_a? Hash
        if relation.polymorphic?
          raise Mongoid::FixtureSet::FixtureError.new "Unable to create document from nested attributes in a polymorphic relation"
        end
        document = relation.class_name.constantize.new
        value = unmarshall_fixture(nil, value, relation.class_name)
        document = self.class.update_document(document, value)
        attributes[relation.foreign_key] = document.id
        return
      end

      if relation.polymorphic? && value.sub!(/\s*\(([^)]*)\)\s*/, '')
        type = $1
        attributes[relation.inverse_type] = type
        attributes[relation.foreign_key]  = self.class.find_or_new_document(type, value).id
      else
        attributes[relation.foreign_key]  = self.class.find_or_new_document(relation.class_name, value).id
      end
    end

    def unmarshall_has_many(model_class, attributes, relation)
      values = attributes.delete(relation.name.to_s)
      return if values.nil?

      values.each do |value|
        if value.is_a? Hash
          document = relation.class_name.constantize.new
          if relation.polymorphic?
            value[relation.foreign_key] = attributes['_id']
            value[relation.type]        = model_class.name
          else
            value[relation.foreign_key] = attributes['_id']
          end
          value = unmarshall_fixture(nil, value, relation.class_name)
          self.class.update_document(document, value)
          next
        end

        document = self.class.find_or_new_document(relation.class_name, value)
        if relation.polymorphic?
          self.class.update_document(document, {
            relation.foreign_key => attributes['_id'],
            relation.type        => model_class.name,
          })
        else
          self.class.update_document(document, {
            relation.foreign_key => attributes['_id']
          })
        end
      end
    end

    def unmarshall_has_and_belongs_to_many(model_class, attributes, relation)
      values = attributes.delete(relation.name.to_s)
      return if values.nil?

      key = relation.foreign_key
      attributes[key] = []

      values.each do |value|
        if value.is_a? Hash
          document = relation.class_name.constantize.new
          value[relation.inverse_foreign_key] = Array(attributes['_id'])
          value = unmarshall_fixture(nil, value, relation.class_name)
          self.class.update_document(document, value)
          attributes[key] << document.id

          next
        end

        document = self.class.find_or_new_document(relation.class_name, value)
        attributes[key] << document.id

        self.class.update_document(document, {
          relation.inverse_foreign_key => Array(attributes['_id'])
        })
      end
    end

    def set_attributes_timestamps(model_class, attributes)
      now = Time.now.utc

      if model_class < Mongoid::Timestamps::Created::Short
        attributes['c_at'] = now        unless attributes.has_key?('c_at')
      elsif model_class < Mongoid::Timestamps::Created
        attributes['created_at'] = now  unless attributes.has_key?('created_at')
      end

      if model_class < Mongoid::Timestamps::Updated::Short
        attributes['u_at'] = now        unless attributes.has_key?('u_at')
      elsif model_class < Mongoid::Timestamps::Updated
        attributes['updated_at'] = now  unless attributes.has_key?('updated_at')
      end
    end

    def read_fixture_files
      yaml_files = Dir["#{path}/{**,*}/*.yml"].select { |f|
        ::File.file?(f)
      } + ["#{path}.yml"]

      yaml_files.each_with_object({}) do |file, fixtures|
        Mongoid::FixtureSet::File.open(file) do |fh|
          fh.each do |fixture_name, row|
            fixtures[fixture_name] = Mongoid::FixtureSet::Fixture.new(fixture_name, row, model_class)
          end
        end
      end
    end

    ##
    # compute the object id based on a string
    def self.fixture_object_id(fixture_name)
      BSON::ObjectId.from_data fixture_name
    end

  end
end
