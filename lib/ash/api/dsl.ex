defmodule Ash.Api.Dsl do
  @resource %Ash.Dsl.Entity{
    name: :resource,
    describe: "A reference to a resource",
    target: Ash.Api.ResourceReference,
    args: [:resource],
    examples: [
      "resource MyApp.User"
    ],
    schema: [
      resource: [
        type: :atom,
        required: true,
        doc: "The module of the resource"
      ]
    ]
  }

  @resources %Ash.Dsl.Section{
    name: :resources,
    describe: "List the resources present in this API",
    examples: [
      """
      resources do
        resource MyApp.User
        resource MyApp.Post
        resource MyApp.Comment
      end
      """
    ],
    schema: [
      define_interfaces?: [
        type: :boolean,
        default: false,
        doc: """
        If set to true, the code interface of each resource will be defined in the api.

        Keep in mind that this can increase the compile times of your application.
        """
      ],
      registry: [
        type: :atom,
        # {:ash_behaviour, Ash.Registry},
        doc: """
        Allows declaring that only the modules in a certain registry should be allowed to work with this Api.

        This option is ignored if any explicit resources are included in the api, so everything is either in the registry
        or in the api. See the docs on `Ash.Registry` for what the registry is used for.
        """
      ]
    ],
    modules: [:registry],
    deprecations: [
      resource: """
      Please define your resources in an `Ash.Registry`. For example:

      # my_app/my_api/registry.ex
      defmodule MyApp.MyApi.Registry do
        use Ash.Registry,
          extensions: [Ash.Registry.ResourceValidations]

        entries do
          entry MyApp.Post
          entry MyApp.Comment
        end
      end

      # In your api module
      resources do
        registry MyApp.MyApi.Registry
      end
      """
    ],
    entities: [
      @resource
    ]
  }

  @sections [@resources]

  @moduledoc """
  A small DSL for declaring APIs

  Apis are the entrypoints for working with your resources.

  Apis may optionally include a list of resources, in which case they can be
  used as an `Ash.Registry` in various places. This is for backwards compatibility,
  but if at all possible you should define an `Ash.Registry` if you are using an extension
  that requires a list of resources. For example, most extensions look for two application
  environment variables called `:ash_apis` and `:ash_registries` to find any potential registries

  # Table of Contents
  #{Ash.Dsl.Extension.doc_index(@sections)}

  #{Ash.Dsl.Extension.doc(@sections)}
  """

  use Ash.Dsl.Extension, sections: @sections
end
