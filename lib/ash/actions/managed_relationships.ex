defmodule Ash.Actions.ManagedRelationships do
  @moduledoc false
  require Ash.Query

  alias Ash.Error.Changes.InvalidRelationship
  alias Ash.Error.Query.NotFound

  def load(_api, created, %{relationships: rels}, _) when rels == %{}, do: {:ok, created}
  def load(_api, created, %{relationships: nil}, _), do: {:ok, created}

  def load(api, created, changeset, opts) do
    if Ash.Changeset.ManagedRelationshipHelpers.must_load?(opts) do
      api.load(created, Map.keys(changeset.relationships),
        authorize?: opts[:authorize?],
        actor: opts[:actor]
      )
    else
      {:ok, created}
    end
  end

  def setup_managed_belongs_to_relationships(changeset, actor, engine_opts) do
    changeset.relationships
    |> Enum.map(fn {relationship, val} ->
      {Ash.Resource.Info.relationship(changeset.resource, relationship), val}
    end)
    |> Enum.filter(fn {relationship, _val} ->
      relationship.type == :belongs_to
    end)
    |> Enum.flat_map(fn {relationship, inputs} ->
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {{input, opts}, index} ->
        {{relationship, {input, opts}}, index}
      end)
    end)
    |> Enum.reject(fn {{_relationship, {input, _opts}}, _index} ->
      is_nil(input) || input == []
    end)
    |> Enum.map(fn
      {{relationship, {[input], opts}}, index} ->
        {{relationship, {input, opts}}, index}

      {{relationship, {other, opts}}, index} ->
        {{relationship, {other, opts}}, index}
    end)
    |> Enum.reduce_while({changeset, %{notifications: []}}, fn {{relationship, {input, opts}},
                                                                index},
                                                               {changeset, instructions} ->
      pkeys = pkeys(relationship)

      opts = Ash.Changeset.ManagedRelationshipHelpers.sanitize_opts(relationship, opts)
      opts = Keyword.put(opts, :authorize?, engine_opts[:authorize?] && opts[:authorize?])
      current_value = Map.get(changeset.data, relationship.name)

      case find_match(List.wrap(current_value), input, pkeys, relationship) do
        nil ->
          case opts[:on_lookup] do
            :ignore ->
              create_belongs_to_record(
                changeset,
                instructions,
                relationship,
                input,
                actor,
                index,
                opts
              )

            {_key, _create_or_update, read} ->
              if is_struct(input) do
                changeset =
                  changeset
                  |> Ash.Changeset.set_context(%{
                    belongs_to_manage_found: %{relationship.name => %{index => input}}
                  })
                  |> Ash.Changeset.force_change_attribute(
                    relationship.source_field,
                    Map.get(input, relationship.destination_field)
                  )

                {:cont, {changeset, instructions}}
              else
                case Ash.Filter.get_filter(relationship.destination, input) do
                  {:ok, keys} ->
                    relationship.destination
                    |> Ash.Query.for_read(read, input, actor: actor)
                    |> Ash.Query.filter(^keys)
                    |> Ash.Query.set_context(relationship.context)
                    |> Ash.Query.limit(1)
                    |> Ash.Query.set_tenant(changeset.tenant)
                    |> changeset.api.read_one(
                      authorize?: opts[:authorize?],
                      actor: actor
                    )
                    |> case do
                      {:ok, nil} ->
                        create_belongs_to_record(
                          changeset,
                          instructions,
                          relationship,
                          input,
                          actor,
                          index,
                          opts
                        )

                      {:ok, found} ->
                        changeset =
                          changeset
                          |> Ash.Changeset.set_context(%{
                            private: %{
                              belongs_to_manage_found: %{relationship.name => %{index => found}}
                            }
                          })
                          |> Ash.Changeset.force_change_attribute(
                            relationship.source_field,
                            Map.get(found, relationship.destination_field)
                          )

                        {:cont, {changeset, instructions}}

                      {:error, error} ->
                        {:halt, {Ash.Changeset.add_error(changeset, error), instructions}}
                    end

                  _ ->
                    {:cont, {changeset, instructions}}
                end
              end
          end

        _value ->
          {:cont, {changeset, instructions}}
      end
    end)
    |> validate_required_belongs_to()
  end

  defp validate_required_belongs_to({changeset, instructions}) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :belongs_to))
    |> Enum.filter(& &1.required?)
    |> Enum.reject(fn relationship ->
      changeset.context[:private][:error][relationship.name]
    end)
    |> Enum.reduce({changeset, instructions}, fn required_relationship,
                                                 {changeset, instructions} ->
      changeset =
        Ash.Changeset.before_action(changeset, fn changeset ->
          case Ash.Changeset.get_attribute(changeset, required_relationship.source_field) do
            nil ->
              Ash.Changeset.add_error(
                changeset,
                Ash.Error.Changes.Required.exception(
                  field: required_relationship.name,
                  type: :relationship
                )
              )

            _ ->
              changeset
          end
        end)

      {changeset, instructions}
    end)
  end

  defp create_belongs_to_record(
         changeset,
         instructions,
         relationship,
         input,
         actor,
         index,
         opts
       ) do
    case opts[:on_no_match] do
      :ignore ->
        {:cont, {changeset, instructions}}

      :error ->
        if opts[:on_lookup] != :ignore do
          changeset =
            changeset
            |> Ash.Changeset.add_error(
              NotFound.exception(
                primary_key: input,
                resource: relationship.destination
              )
            )
            |> Ash.Changeset.put_context(:private, %{error: %{relationship.name => true}})

          {:halt, {changeset, instructions}}
        else
          changeset =
            changeset
            |> Ash.Changeset.add_error(
              InvalidRelationship.exception(
                relationship: relationship.name,
                message: "Changes would create a new related record"
              )
            )
            |> Ash.Changeset.put_context(:private, %{error: %{relationship.name => true}})

          {:halt, {changeset, instructions}}
        end

      {:create, action_name} ->
        do_create_belongs_to_record(
          relationship,
          action_name,
          input,
          changeset,
          actor,
          opts,
          instructions,
          index
        )
    end
  end

  defp do_create_belongs_to_record(
         relationship,
         action_name,
         input,
         changeset,
         actor,
         opts,
         instructions,
         index
       ) do
    relationship.destination
    |> Ash.Changeset.for_create(action_name, input,
      require?: false,
      actor: actor,
      relationships: opts[:relationships] || []
    )
    |> Ash.Changeset.set_context(relationship.context)
    |> Ash.Changeset.set_tenant(changeset.tenant)
    |> changeset.api.create(
      actor: actor,
      authorize?: opts[:authorize?],
      return_notifications?: true
    )
    |> case do
      {:ok, created, notifications} ->
        changeset =
          changeset
          |> Ash.Changeset.set_context(%{
            private: %{
              belongs_to_manage_created: %{relationship.name => %{index => created}}
            }
          })
          |> Ash.Changeset.force_change_attribute(
            relationship.source_field,
            Map.get(created, relationship.destination_field)
          )

        {:cont,
         {changeset, %{instructions | notifications: instructions.notifications ++ notifications}}}

      {:error, error} ->
        {:halt, {Ash.Changeset.add_error(changeset, error), instructions}}
    end
  end

  def manage_relationships(record, changeset, actor, engine_opts) do
    changeset.relationships
    |> Enum.map(fn {relationship, val} ->
      {Ash.Resource.Info.relationship(changeset.resource, relationship), val}
    end)
    |> Enum.flat_map(fn {key, batches} ->
      batches
      |> Enum.with_index()
      |> Enum.map(fn {{batch, opts}, index} ->
        opts = Keyword.put(opts, :authorize?, engine_opts[:authorize?] && opts[:authorize?])
        {key, batch, opts, index}
      end)
    end)
    |> Enum.reduce_while({:ok, record, []}, fn {relationship, inputs, opts, index},
                                               {:ok, record, all_notifications} ->
      inputs =
        if relationship.cardinality == :many do
          List.wrap(inputs)
        else
          inputs
        end

      case manage_relationship(record, relationship, inputs, changeset, actor, index, opts) do
        {:ok, record, notifications} ->
          record =
            if relationship.type == :many_to_many do
              Map.put(
                record,
                relationship.join_relationship,
                Map.get(record.__struct__.__struct__, relationship.join_relationship)
              )
            else
              record
            end

          {:cont, {:ok, record, notifications ++ all_notifications}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp pkeys(relationship) do
    identities =
      relationship.destination
      |> Ash.Resource.Info.identities()
      |> Enum.map(& &1.keys)

    [Ash.Resource.Info.primary_key(relationship.destination) | identities]
  end

  defp manage_relationship(
         record,
         %{cardinality: :many} = relationship,
         inputs,
         changeset,
         actor,
         index,
         opts
       ) do
    inputs = List.wrap(inputs)
    opts = Ash.Changeset.ManagedRelationshipHelpers.sanitize_opts(relationship, opts)
    pkeys = pkeys(relationship)
    original_value = List.wrap(Map.get(record, relationship.name))

    inputs
    |> Enum.reduce_while(
      {:ok, [], [], []},
      fn input, {:ok, current_value, all_notifications, all_used} ->
        case handle_input(
               record,
               current_value,
               original_value,
               relationship,
               input,
               pkeys,
               changeset,
               actor,
               index,
               opts
             ) do
          {:ok, new_value, notifications, used} ->
            {:cont, {:ok, new_value, all_notifications ++ notifications, all_used ++ used}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    )
    |> case do
      {:ok, new_value, all_notifications, all_used} ->
        case delete_unused(
               record,
               original_value,
               relationship,
               new_value,
               all_used,
               changeset,
               actor,
               opts
             ) do
          {:ok, new_value, notifications} ->
            {:ok, Map.put(record, relationship.name, new_value),
             all_notifications ++ notifications}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp manage_relationship(
         record,
         %{cardinality: :one} = relationship,
         inputs,
         changeset,
         actor,
         index,
         opts
       ) do
    opts = Ash.Changeset.ManagedRelationshipHelpers.sanitize_opts(relationship, opts)

    identities =
      relationship.destination
      |> Ash.Resource.Info.identities()
      |> Enum.map(& &1.keys)

    pkeys = [Ash.Resource.Info.primary_key(relationship.destination) | identities]
    original_value = List.wrap(Map.get(record, relationship.name))
    inputs = List.wrap(inputs)

    inputs
    |> Enum.reduce_while(
      {:ok, original_value, [], []},
      fn input, {:ok, current_value, all_notifications, all_used} ->
        case handle_input(
               record,
               current_value,
               original_value,
               relationship,
               input,
               pkeys,
               changeset,
               actor,
               index,
               opts
             ) do
          {:ok, new_value, notifications, used} ->
            {:cont, {:ok, new_value, all_notifications ++ notifications, all_used ++ used}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    )
    |> case do
      {:ok, new_value, all_notifications, all_used} ->
        case delete_unused(
               record,
               original_value,
               relationship,
               new_value,
               all_used,
               changeset,
               actor,
               opts
             ) do
          {:ok, new_value, notifications} ->
            {:ok, Map.put(record, relationship.name, Enum.at(List.wrap(new_value), 0)),
             all_notifications ++ notifications}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp handle_input(
         record,
         current_value,
         original_value,
         relationship,
         input,
         pkeys,
         changeset,
         actor,
         index,
         opts
       ) do
    match = find_match(List.wrap(original_value), input, pkeys, relationship)

    if is_nil(match) || opts[:on_match] == :no_match do
      case handle_create(
             record,
             current_value,
             relationship,
             input,
             changeset,
             actor,
             index,
             opts
           ) do
        {:ok, current_value, notifications, used} ->
          {:ok, current_value, notifications, used}

        {:error, error} ->
          {:error, error}
      end
    else
      handle_update(record, current_value, relationship, match, input, changeset, actor, opts)
    end
  end

  defp handle_create(record, current_value, relationship, input, changeset, actor, index, opts) do
    api = changeset.api

    case opts[:on_lookup] do
      :ignore ->
        do_handle_create(
          record,
          current_value,
          relationship,
          input,
          changeset,
          actor,
          index,
          opts
        )

      other ->
        case Map.fetch(
               changeset.context[:private][:belongs_to_manage_found][relationship.name] || %{},
               index
             ) do
          :error ->
            {key, create_or_update, read, join_keys} =
              case other do
                {key, create_or_update, read} -> {key, create_or_update, read, []}
                {key, create_or_update, read, keys} -> {key, create_or_update, read, keys}
              end

            case Ash.Filter.get_filter(relationship.destination, input) do
              {:ok, keys} ->
                if is_struct(input) do
                  {:ok, input}
                else
                  relationship.destination
                  |> Ash.Query.for_read(read, input, actor: actor)
                  |> Ash.Query.filter(^keys)
                  |> Ash.Query.set_context(relationship.context)
                  |> Ash.Query.set_tenant(changeset.tenant)
                  |> Ash.Query.limit(1)
                  |> changeset.api.read_one(
                    authorize?: opts[:authorize?],
                    actor: actor
                  )
                end
                |> case do
                  {:ok, found} when not is_nil(found) ->
                    do_handle_found(
                      relationship,
                      join_keys,
                      input,
                      api,
                      opts,
                      found,
                      current_value,
                      create_or_update,
                      actor,
                      key,
                      record,
                      changeset
                    )

                  {:ok, _} ->
                    do_handle_create(
                      record,
                      current_value,
                      relationship,
                      input,
                      changeset,
                      actor,
                      index,
                      opts
                    )

                  {:error, error} ->
                    {:error, error}
                end

              {:error, _error} ->
                do_handle_create(
                  record,
                  current_value,
                  relationship,
                  input,
                  changeset,
                  actor,
                  index,
                  opts
                )
            end

          {:ok, found} ->
            {:ok, [found | current_value], [], [found]}
        end
    end
  end

  defp do_handle_found(
         relationship,
         join_keys,
         input,
         api,
         opts,
         found,
         current_value,
         create_or_update,
         actor,
         key,
         record,
         changeset
       ) do
    case relationship.type do
      :many_to_many ->
        input =
          if is_map(input) do
            input
          else
            Enum.into(input, %{})
          end

        {join_input, input} = split_join_keys(input, join_keys)

        join_relationship =
          Ash.Resource.Info.relationship(
            relationship.source,
            relationship.join_relationship
          )

        relationship.through
        |> Ash.Changeset.new()
        |> Ash.Changeset.for_create(create_or_update, join_input, actor: actor)
        |> Ash.Changeset.force_change_attribute(
          relationship.source_field_on_join_table,
          Map.get(record, relationship.source_field)
        )
        |> Ash.Changeset.force_change_attribute(
          relationship.destination_field_on_join_table,
          Map.get(found, relationship.destination_field)
        )
        |> Ash.Changeset.set_context(join_relationship.context)
        |> Ash.Changeset.set_tenant(changeset.tenant)
        |> api.create(
          return_notifications?: true,
          authorize?: opts[:authorize?],
          actor: actor
        )
        |> case do
          {:ok, _created, notifications} ->
            case key do
              :relate ->
                {:ok, [found | current_value], notifications, [found]}

              :relate_and_update ->
                case handle_update(
                       record,
                       current_value,
                       relationship,
                       found,
                       input,
                       changeset,
                       actor,
                       opts
                     ) do
                  {:ok, new_value, update_notifications, used} ->
                    {:ok, new_value, update_notifications ++ notifications, used}

                  {:error, error} ->
                    {:error, error}
                end
            end

          {:error, error} ->
            {:error, error}
        end

      type when type in [:has_many, :has_one] ->
        {found, input} =
          if is_struct(input) do
            {input, %{}}
          else
            {found, input}
          end

        found
        |> Ash.Changeset.for_update(create_or_update, input,
          relationships: opts[:relationships] || [],
          actor: actor
        )
        |> Ash.Changeset.force_change_attribute(
          relationship.destination_field,
          Map.get(record, relationship.source_field)
        )
        |> Ash.Changeset.set_context(relationship.context)
        |> Ash.Changeset.set_tenant(changeset.tenant)
        |> api.update(
          return_notifications?: true,
          authorize?: opts[:authorize?],
          actor: actor
        )
        |> case do
          {:ok, updated, notifications} ->
            {:ok, [updated | current_value], notifications, [updated]}

          {:error, error} ->
            {:error, error}
        end

      :belongs_to ->
        {:ok, [found | current_value], [], [found]}
    end
  end

  defp do_handle_create(record, current_value, relationship, input, changeset, actor, index, opts) do
    case opts[:on_no_match] do
      :error ->
        if opts[:on_lookup] != :ignore do
          {:error,
           NotFound.exception(
             primary_key: input,
             resource: relationship.destination
           )}
        else
          {:error,
           InvalidRelationship.exception(
             relationship: relationship.name,
             message: "Changes would create a new related record"
           )}
        end

      {:create, action_name} ->
        case changeset.context[:private][:belongs_to_manage_created][relationship.name][index] do
          nil ->
            created =
              if is_struct(input) do
                {:ok, input, [], []}
              else
                relationship.destination
                |> Ash.Changeset.for_create(action_name, input,
                  require?: false,
                  actor: actor,
                  relationships: opts[:relationships]
                )
                |> Ash.Changeset.force_change_attribute(
                  relationship.destination_field,
                  Map.get(record, relationship.source_field)
                )
                |> Ash.Changeset.set_context(relationship.context)
                |> Ash.Changeset.set_tenant(changeset.tenant)
                |> changeset.api.create(
                  return_notifications?: true,
                  authorize?: opts[:authorize?],
                  actor: actor
                )
              end

            case created do
              {:ok, created, notifications} ->
                {:ok, [created | current_value], notifications, []}

              {:error, error} ->
                {:error, error}
            end

          created ->
            {:ok, [created | current_value], [], []}
        end

      {:create, action_name, join_action_name, params} ->
        join_keys = params ++ Enum.map(params, &to_string/1)

        input =
          if is_map(input) do
            input
          else
            Enum.into(input, %{})
          end

        {join_params, regular_params} = split_join_keys(input, join_keys)

        created =
          if is_struct(input) do
            {:ok, input, []}
          else
            relationship.destination
            |> Ash.Changeset.for_create(action_name, regular_params,
              require?: false,
              relationships: opts[:relationships],
              actor: actor
            )
            |> Ash.Changeset.set_context(relationship.context)
            |> Ash.Changeset.set_tenant(changeset.tenant)
            |> changeset.api.create(
              return_notifications?: true,
              authorize?: opts[:authorize?],
              actor: actor
            )
          end

        case created do
          {:ok, created, regular_notifications} ->
            join_relationship =
              Ash.Resource.Info.relationship(relationship.source, relationship.join_relationship)

            relationship.through
            |> Ash.Changeset.new()
            |> Ash.Changeset.for_create(join_action_name, join_params,
              require?: false,
              actor: actor
            )
            |> Ash.Changeset.force_change_attribute(
              relationship.source_field_on_join_table,
              Map.get(record, relationship.source_field)
            )
            |> Ash.Changeset.force_change_attribute(
              relationship.destination_field_on_join_table,
              Map.get(created, relationship.destination_field)
            )
            |> Ash.Changeset.set_context(join_relationship.context)
            |> Ash.Changeset.set_tenant(changeset.tenant)
            |> changeset.api.create(
              return_notifications?: true,
              authorize?: opts[:authorize?],
              actor: actor
            )
            |> case do
              {:ok, _join_row, notifications} ->
                {:ok, [created | current_value], regular_notifications ++ notifications, []}

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end

      :ignore ->
        {:ok, current_value, [], []}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp handle_update(
         source_record,
         current_value,
         relationship,
         match,
         input,
         changeset,
         actor,
         opts
       ) do
    api = changeset.api

    case opts[:on_match] do
      # :create case is handled when determining updates/creates

      :error ->
        {:error,
         InvalidRelationship.exception(
           relationship: relationship.name,
           message: "Changes would update a record"
         )}

      :ignore ->
        {:ok, [match | current_value], [], [match]}

      :missing ->
        {:ok, current_value, [], []}

      {:unrelate, action_name} ->
        case unrelate_data(
               source_record,
               match,
               api,
               actor,
               opts,
               action_name,
               changeset.tenant,
               relationship
             ) do
          {:ok, notifications} ->
            {:ok, current_value, notifications, []}

          {:error, error} ->
            {:error, error}
        end

      {:update, action_name} ->
        {match, input} =
          if is_struct(input) do
            {input, %{}}
          else
            {match, input}
          end

        match
        |> Ash.Changeset.for_update(action_name, input,
          actor: actor,
          relationships: opts[:relationships] || []
        )
        |> Ash.Changeset.set_context(relationship.context)
        |> Ash.Changeset.set_tenant(changeset.tenant)
        |> api.update(actor: actor, authorize?: opts[:authorize?], return_notifications?: true)
        |> case do
          {:ok, updated, update_notifications} ->
            {:ok, [updated | current_value], update_notifications, [match]}

          {:error, error} ->
            {:error, error}
        end

      {:update, action_name, join_action_name, params} ->
        join_keys = params ++ Enum.map(params, &to_string/1)
        {join_params, regular_params} = split_join_keys(input, join_keys)

        {match, regular_params} =
          if is_struct(regular_params) do
            {regular_params, %{}}
          else
            {match, regular_params}
          end

        source_value = Map.get(source_record, relationship.source_field)

        match
        |> Ash.Changeset.for_update(action_name, regular_params,
          actor: actor,
          relationships: opts[:relationships]
        )
        |> Ash.Changeset.set_context(relationship.context)
        |> Ash.Changeset.set_tenant(changeset.tenant)
        |> api.update(actor: actor, authorize?: opts[:authorize?], return_notifications?: true)
        |> case do
          {:ok, updated, update_notifications} ->
            destination_value = Map.get(updated, relationship.destination_field)

            join_relationship =
              Ash.Resource.Info.relationship(relationship.source, relationship.join_relationship)

            relationship.through
            |> Ash.Query.filter(ref(^relationship.source_field_on_join_table) == ^source_value)
            |> Ash.Query.filter(
              ref(^relationship.destination_field_on_join_table) == ^destination_value
            )
            |> Ash.Query.set_context(join_relationship.context)
            |> Ash.Query.limit(1)
            |> Ash.Query.set_tenant(changeset.tenant)
            |> changeset.api.read_one(
              authorize?: opts[:authorize?],
              actor: actor
            )
            |> case do
              {:ok, result} ->
                if join_params == %{} do
                  {:ok, [updated | current_value], update_notifications, [match]}
                else
                  join_relationship =
                    Ash.Resource.Info.relationship(
                      relationship.source,
                      relationship.join_relationship
                    )

                  result
                  |> Ash.Changeset.for_update(join_action_name, join_params, actor: actor)
                  |> Ash.Changeset.set_context(join_relationship.context)
                  |> Ash.Changeset.set_tenant(changeset.tenant)
                  |> api.update(
                    return_notifications?: true,
                    authorize?: opts[:authorize?],
                    actor: actor
                  )
                  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                  |> case do
                    {:ok, _updated_join, join_update_notifications} ->
                      {:ok, [updated | current_value],
                       update_notifications ++ join_update_notifications, [updated]}

                    {:error, error} ->
                      {:error, error}
                  end
                end

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp find_match(current_value, input, pkeys, relationship \\ nil)

  defp find_match(%Ash.NotLoaded{}, _input, _pkeys, _relationship) do
    nil
  end

  defp find_match(current_value, input, pkeys, relationship) do
    Enum.find(current_value, fn current_value ->
      Enum.any?(pkeys, fn pkey ->
        matches?(current_value, input, pkey, relationship)
      end)
    end)
  end

  defp matches?(current_value, input, pkey, relationship) do
    if relationship && relationship.type in [:has_one, :has_many] &&
         relationship.destination_field in pkey do
      Enum.all?(pkey, fn field ->
        if field == relationship.destination_field do
          if is_struct(input) do
            do_matches?(current_value, input, field)
          else
            # We know that it will be the same as all other records in this relationship
            # (because thats how has_one and has_many relationships work), so we
            # can assume its the same as the current value
            true
          end
        else
          do_matches?(current_value, input, field)
        end
      end)
    else
      Enum.all?(pkey, fn field ->
        do_matches?(current_value, input, field)
      end)
    end
  end

  defp do_matches?(current_value, input, field) do
    with {:ok, current_val} <- Map.fetch(current_value, field),
         {:ok, input_val} <- fetch_field(input, field) do
      current_val == input_val
    else
      _ ->
        false
    end
  end

  defp split_join_keys(%_{__metadata__: metadata} = input, _join_keys) do
    {metadata[:join_keys] || %{}, input}
  end

  defp split_join_keys(input, :all) do
    {input, %{}}
  end

  defp split_join_keys(input, join_keys) do
    Map.split(input, join_keys ++ Enum.map(join_keys, &to_string/1))
  end

  defp fetch_field(input, field) do
    case Map.fetch(input, field) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(input, to_string(field))
    end
  end

  defp delete_unused(
         source_record,
         original_value,
         relationship,
         current_value,
         all_used,
         changeset,
         actor,
         opts
       ) do
    api = changeset.api
    pkey = Ash.Resource.Info.primary_key(relationship.destination)

    original_value
    |> List.wrap()
    |> Enum.reject(&find_match(all_used, &1, [pkey]))
    |> Enum.reduce_while(
      {:ok, current_value, []},
      fn record, {:ok, current_value, all_notifications} ->
        case opts[:on_missing] do
          :ignore ->
            {:cont, {:ok, [record | current_value], []}}

          {:destroy, action_name, join_action_name} ->
            source_value = Map.get(source_record, relationship.source_field)
            destination_value = Map.get(record, relationship.destination_field)

            relationship.through
            |> Ash.Query.filter(ref(^relationship.source_field_on_join_table) == ^source_value)
            |> Ash.Query.filter(
              ref(^relationship.destination_field_on_join_table) == ^destination_value
            )
            |> Ash.Query.limit(1)
            |> Ash.Query.set_tenant(changeset.tenant)
            |> api.read_one(
              authorize?: opts[:authorize?],
              actor: actor
            )
            |> case do
              {:ok, result} ->
                join_relationship =
                  Ash.Resource.Info.relationship(
                    relationship.source,
                    relationship.join_relationship
                  )

                result
                |> Ash.Changeset.for_destroy(
                  join_action_name,
                  %{},
                  actor: actor
                )
                |> Ash.Changeset.set_context(join_relationship.context)
                |> Ash.Changeset.set_tenant(changeset.tenant)
                |> api.destroy(
                  return_notifications?: true,
                  authorize?: opts[:authorize?],
                  actor: actor
                )
                |> case do
                  {:ok, join_notifications} ->
                    notifications = join_notifications ++ all_notifications

                    record
                    |> Ash.Changeset.for_destroy(action_name, %{}, actor: actor)
                    |> Ash.Changeset.set_context(relationship.context)
                    |> Ash.Changeset.set_tenant(changeset.tenant)
                    |> api.destroy(
                      return_notifications?: true,
                      authorize?: opts[:authorize?],
                      actor: actor
                    )
                    # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                    |> case do
                      {:ok, destroy_destination_notifications} ->
                        {:cont,
                         {:ok, current_value,
                          notifications ++
                            all_notifications ++ destroy_destination_notifications}}

                      {:error, error} ->
                        {:halt, {:error, error}}
                    end

                  {:error, error} ->
                    {:halt, {:error, error}}
                end

              {:error, error} ->
                {:halt, {:error, error}}
            end

          {:destroy, action_name} ->
            record
            |> Ash.Changeset.for_destroy(action_name, %{}, actor: actor)
            |> Ash.Changeset.set_context(relationship.context)
            |> Ash.Changeset.set_tenant(changeset.tenant)
            |> api.destroy(
              authorize?: opts[:authorize?],
              actor: actor,
              return_notifications?: true
            )
            |> case do
              {:ok, notifications} ->
                {:cont, {:ok, current_value, notifications ++ all_notifications}}

              {:error, error} ->
                {:halt, {:error, error}}
            end

          :error ->
            {:halt,
             {:error,
              InvalidRelationship.exception(
                relationship: relationship.name,
                message: "Changes would destroy a record"
              )}}

          {:unrelate, action_name} ->
            case unrelate_data(
                   source_record,
                   record,
                   api,
                   actor,
                   opts,
                   action_name,
                   changeset.tenant,
                   relationship
                 ) do
              {:ok, notifications} ->
                {:cont, {:ok, current_value, notifications}}

              {:error, error} ->
                {:halt, {:error, error}}
            end
        end
      end
    )
  end

  defp unrelate_data(
         source_record,
         record,
         api,
         actor,
         opts,
         action_name,
         tenant,
         %{type: :many_to_many} = relationship
       ) do
    action_name =
      action_name || Ash.Resource.Info.primary_action(relationship.through, :destroy).name

    source_value = Map.get(source_record, relationship.source_field)
    destination_value = Map.get(record, relationship.destination_field)

    relationship.through
    |> Ash.Query.filter(ref(^relationship.source_field_on_join_table) == ^source_value)
    |> Ash.Query.filter(ref(^relationship.destination_field_on_join_table) == ^destination_value)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(tenant)
    |> api.read_one(authorize?: opts[:authorize?], actor: actor)
    |> case do
      {:ok, result} ->
        result
        |> Ash.Changeset.for_destroy(action_name, %{}, actor: actor)
        |> Ash.Changeset.set_context(relationship.context)
        |> Ash.Changeset.set_tenant(tenant)
        |> api.destroy(
          return_notifications?: true,
          authorize?: opts[:authorize?],
          actor: actor
        )
        |> case do
          {:ok, notifications} ->
            {:ok, notifications}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp unrelate_data(
         _source_record,
         record,
         api,
         actor,
         opts,
         action_name,
         tenant,
         %{type: type} = relationship
       )
       when type in [:has_many, :has_one] do
    action_name =
      action_name || Ash.Resource.Info.primary_action(relationship.destination, :update).name

    record
    |> Ash.Changeset.for_update(action_name, %{},
      relationships: opts[:relationships] || [],
      actor: actor
    )
    |> Ash.Changeset.force_change_attribute(relationship.destination_field, nil)
    |> Ash.Changeset.set_context(relationship.context)
    |> Ash.Changeset.set_tenant(tenant)
    |> api.update(return_notifications?: true, actor: actor, authorize?: opts[:authorize?])
    |> case do
      {:ok, _unrelated, notifications} ->
        {:ok, notifications}

      {:error, error} ->
        {:error, error}
    end
  end

  defp unrelate_data(
         source_record,
         _record,
         api,
         actor,
         opts,
         action_name,
         tenant,
         %{type: :belongs_to} = relationship
       ) do
    action_name =
      action_name || Ash.Resource.Info.primary_action(relationship.source, :update).name

    source_record
    |> Ash.Changeset.for_update(action_name, %{},
      relationships: opts[:relationships] || [],
      actor: actor
    )
    |> Ash.Changeset.force_change_attribute(relationship.source_field, nil)
    |> Ash.Changeset.set_context(relationship.context)
    |> Ash.Changeset.set_tenant(tenant)
    |> api.update(return_notifications?: true, actor: actor, authorize?: opts[:authorize?])
    |> case do
      {:ok, _unrelated, notifications} ->
        {:ok, notifications}

      {:error, error} ->
        {:error, error}
    end
  end
end
