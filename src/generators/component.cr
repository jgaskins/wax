require "./generator"

module Wax::Generators
  class Component < Generator
    handle "component"

    getter name : String

    def self.description
      "Generate an Armature component"
    end

    def self.new(args : Array(String))
      new args.first
    end

    def initialize(@name)
    end

    def call
      file "src/components/#{name.underscore}.cr", <<-EOF
        require "armature/component"

        struct #{name.camelcase(lower: false)} < Armature::Component
          # def initialize(...)
          # end

          def_to_s "components/#{name.underscore}"
        end
        EOF

      template_filename = "views/components/#{name.underscore}.ecr"
      file template_filename, <<-EOF
        <div><%= self.class %> defined in <code>#{template_filename}</code></div>
        EOF
    end
  end
end
