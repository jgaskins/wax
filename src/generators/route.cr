require "./generator"

module Wax::Generators
  class Route < Generator
    handle "route"

    getter name : String

    def self.description
      "Generate an Armature route"
    end

    def self.new(args : Array(String))
      new args.first
    end

    def initialize(@name)
    end

    def call
      file "src/routes/#{@name.underscore.gsub("::", "/")}.cr", <<-EOF
        require "./route"

        struct #{@name.camelcase(lower: false)}
          include Route

          def call(context)
            route context do |r, response, session|
              r.root do
                r.get do
                  # ...
                end

                r.post do
                  # ...
                end
              end

              r.on id: UUID do |id|
                # Make sure you use HTTP methods like `r.get` or `r.post` to indicate
                # a terminal route for Armature.
              end
            end
          end
        end
        EOF
    end
  end
end
