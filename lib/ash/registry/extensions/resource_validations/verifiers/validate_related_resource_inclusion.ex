defmodule Ash.Registry.ResourceValidations.Verifiers.ValidateRelatedResourceInclusion do
  @moduledoc """
  Ensures that all related resources are included in an API.
  """
  use Spark.Dsl.Verifier
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    resources =
      dsl
      |> Verifier.get_entities([:entries])
      |> Enum.map(& &1.entry)

    for resource <- resources do
      for relationship <- Ash.Resource.Info.relationships(resource) do
        message =
          if relationship.api do
            "is not accepted by api `#{inspect(relationship.api)}`"
          else
            "is not in registry `#{inspect(Verifier.get_persisted(dsl, :module))}`"
          end

        unless resource_accepted?(
                 relationship.api,
                 relationship.destination,
                 Verifier.get_persisted(dsl, :module),
                 resources
               ) do
          if relationship.type == :has_many && relationship.autogenerated_join_relationship_of do
            parent_relationship =
              Ash.Resource.Info.relationship(
                resource,
                relationship.autogenerated_join_relationship_of
              )

            raise """
            Resource `#{inspect(relationship.destination)}` #{message} for autogenerated join relationship: `:#{relationship.name}`

            Relationship was generated by the `many_to_many` relationship `#{inspect(parent_relationship.name)}`

            If the `through` resource `#{inspect(relationship.destination)}` is not accepted by the same
            api as the destination resource `#{inspect(parent_relationship.destination)}`,
            then you must define that relationship manually. To define it manually, add the following to your
            relationships:

                has_many :#{relationship.name}, #{inspect(relationship.destination)} do
                  # configure the relationship attributes
                  ...
                end

            You can use a name other than `:#{relationship.name}`, but if you do, make sure to
            add that to `:#{parent_relationship.name}`, i.e

                many_to_many :#{relationship.name}, #{inspect(relationship.destination)} do
                  ...
                  join_relationship_name :your_new_name
                end
            """
          else
            raise """
            Resource `#{inspect(relationship.destination)}` in relationship `:#{relationship.name}` #{message}. Please do one of the following

            1. add the resource to the registry `#{inspect(registry(relationship, dsl))}`
            2. configure a different api
            """
          end
        end
      end
    end

    :ok
  end

  defp registry(relationship, dsl) do
    if relationship.api do
      Ash.Api.Info.registry(relationship.api)
    else
      Verifier.get_persisted(dsl, :module)
    end
  end

  defp resource_accepted?(nil, destination, _registry, resources) do
    destination in resources
  end

  defp resource_accepted?(api, destination, registry_module, resources) do
    if Ash.Api.Info.registry(api) == registry_module do
      destination in resources
    else
      match?({:ok, _}, Ash.Api.Info.resource(api, destination))
    end
  end
end
