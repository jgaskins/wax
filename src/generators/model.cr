require "./generator"

module Wax::Generators
  class Model < Generator
    handle "model"

    getter name : String
    getter properties : Array(Property)

    def self.description
      "Generate an Interro model type"
    end

    def self.new(properties : Array(String))
      type_name, *properties = properties

      properties = properties.flat_map do |raw|
        components = raw.split(':')
        case components
        when %w[id]
          Property.new(
            name: "id",
            crystal_type: "UUID",
            sql_type: "UUID",
            primary_key: true,
          )
        when %w[timestamps]
          [
            Property.new(
              name: "created_at",
              crystal_type: "Time",
              sql_type: "TIMESTAMPTZ",
              default: "now()",
            ),
            Property.new(
              name: "updated_at",
              crystal_type: "Time",
              sql_type: "TIMESTAMPTZ",
              default: "now()",
            ),
          ]
        else
          unless (name = components[0]?) && (type = components[1]?)
            raise ArgumentError.new("Must supply property in the format `name:type` or `name:type:modifier1:modifier2:...`")
            exit 1
          end
          if (invalid = components[2..].reject { |component| valid_modifier? component }).any?
            raise ArgumentError.new("Invalid property modifier#{'s' if invalid.size != 1} for #{name}:#{type} - #{invalid}. Can only be: #{valid_modifiers + additional_modifiers}")
          end
          nullable = components.includes?("optional")
          unique = components.includes?("unique")
          pkey = components.includes?("pkey")
          if default_component = components.compact_map(&.match(/default\((.*)\)/)).first?
            default = default_component[1]
          end

          crystal_type = CRYSTAL_TYPE_MAP.fetch(type) do |k|
            k.camelcase lower: false
          end

          sql_type = SQL_TYPE_MAP.fetch(type) do |k|
            k.upcase
          end

          Property.new(
            name: name,
            crystal_type: crystal_type,
            sql_type: sql_type,
            nullable: nullable,
            unique: unique,
            primary_key: pkey,
            default: default,
          )
        end
      end

      new type_name, properties
    end

    def initialize(@name, @properties)
    end

    def call
      model_file
      query_file
      migration_files
    end

    def self.valid_modifier?(modifier : String)
      return true if valid_modifiers.includes? modifier
      return true if modifier =~ /default(.*)/
      false
    end

    def self.valid_modifiers
      %w[optional unique pkey]
    end

    def self.additional_modifiers
      ["default(SQL expression)"]
    end

    def query_file
      code = String.build do |string|
        string.puts %{require "./query"}
        string.puts
        string.puts %{src "models/#{name.underscore}"}
        string.puts
        string.puts "struct #{model_name}Query < Query(#{model_name})"
        string.puts %{  table "#{table_name}"}
        string.puts "end"
      end

      file "src/queries/#{name.underscore}.cr", code
    end

    def model_file
      code = String.build do |string|
        string.puts %{require "./model"}
        string.puts
        string.puts "struct #{model_name} < Model"
        properties.each do |property|
          property.to_crystal string
          string.puts
        end

        string.puts "end"
      end

      file "src/models/#{name.underscore}.cr", code
    end

    def migration_files
      up = String.build do |string|
        string.puts "CREATE TABLE #{table_name}("
        properties.each_with_index 1 do |property, index|
          string << "  "
          property.to_sql string
          if index < properties.size
            string << ','
          end
          string.puts
        end
        string.puts ")"
      end
      down = String.build do |string|
        string.puts "DROP TABLE #{table_name}"
      end

      now = Time.utc
      timestamp = "%04d_%02d_%02d_%02d_%02d_%02d_%09d" % {
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
        now.nanosecond,
      }
      dir = "db/migrations/#{timestamp}-Create#{plural_model_name}"
      file "#{dir}/up.sql", up
      file "#{dir}/down.sql", down
    end

    def model_name
      name.camelcase(lower: false)
    end

    def plural_model_name
      plural_name.camelcase(lower: false)
    end

    def table_name
      plural_name.underscore
    end

    def plural_name
      case name
      when .ends_with? 'y'
        "#{name[0...-1]}ies"
      else
        "#{name}s"
      end
    end

    private struct Property
      getter name : String
      getter crystal_type : String
      getter sql_type : String
      getter? nullable : Bool
      getter? unique : Bool
      getter? primary_key : Bool
      getter default : String?

      def initialize(
        @name,
        *,
        @crystal_type,
        @sql_type,
        @nullable = false,
        @unique = false,
        @primary_key = false,
        @default = nil
      )
      end

      def to_crystal(io) : Nil
        io << "  getter #{name} : #{crystal_type}"
        if nullable?
          io << '?'
        end
      end

      def to_sql(io) : Nil
        io << name << ' ' << sql_type

        if primary_key?
          io << " PRIMARY KEY"
        end

        if unique?
          io << " UNIQUE"
        end

        unless nullable?
          io << " NOT NULL"
        end

        if default
          io << " DEFAULT " << default
        end
      end
    end

    private CRYSTAL_TYPE_MAP = {
      "uuid"     => "UUID",
      "password" => "BCrypt::Password",
      "int16"    => "Int16",
      "int32"    => "Int32",
      "int64"    => "Int64",
      "time"     => "Time",
    }

    private SQL_TYPE_MAP = {
      "password" => "TEXT",
      "string"   => "TEXT",
      "int16"    => "INT2",
      "int32"    => "INT4",
      "int64"    => "INT8",
      "time"     => "TIMESTAMPTZ",
    }
  end
end
