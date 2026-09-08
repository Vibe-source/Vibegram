defmodule Vibe.Schemas.NotificationPreference do
  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(privateChats groupChats channels stories reactions)
  @boolean_keys ~w(allAccounts inAppSounds inAppVibrate inAppPreview namesOnLockScreen)
  @category_keys ~w(enabled sound preview)

  @default_category_settings %{"enabled" => true, "sound" => "default", "preview" => true}

  @default_preferences %{
    "privateChats" => @default_category_settings,
    "groupChats" => @default_category_settings,
    "channels" => @default_category_settings,
    "stories" => @default_category_settings,
    "reactions" => @default_category_settings,
    "allAccounts" => true,
    "inAppSounds" => true,
    "inAppVibrate" => true,
    "inAppPreview" => true,
    "namesOnLockScreen" => true
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_preferences" do
    field(:user_id, :binary_id)
    field(:preferences, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories
  def default_preferences, do: @default_preferences


  @wire_categories %{
    "private_chats" => "privateChats",
    "group_chats" => "groupChats",
    "channels" => "channels",
    "stories" => "stories",
    "reactions" => "reactions"
  }

  @wire_booleans %{
    "all_accounts" => "allAccounts",
    "in_app_sounds" => "inAppSounds",
    "in_app_vibrate" => "inAppVibrate",
    "in_app_preview" => "inAppPreview",
    "names_on_lock_screen" => "namesOnLockScreen"
  }

  @default_sound "default"

  @doc """
  Client payload -> stored shape, for a partial update.
  """
  def from_wire(updates) when is_map(updates) do
    updates = stringify_keys(updates)

    if wire_shaped?(updates) do
      categories =
        updates
        |> Map.get("categories", %{})
        |> case do
          map when is_map(map) -> map
          _ -> %{}
        end
        |> Enum.reduce(%{}, fn {wire_key, settings}, acc ->
          case {Map.fetch(@wire_categories, wire_key), settings} do
            {{:ok, key}, settings} when is_map(settings) ->
              Map.put(acc, key, from_wire_category(settings))

            _ ->
              acc
          end
        end)

      Enum.reduce(@wire_booleans, categories, fn {wire_key, key}, acc ->
        case Map.fetch(updates, wire_key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)
    else
      updates
    end
  end

  def from_wire(updates), do: updates

  @doc "Stored shape -> client payload."
  def to_wire(preferences) when is_map(preferences) do
    normalized = normalize(preferences)

    categories =
      Enum.reduce(@wire_categories, %{}, fn {wire_key, key}, acc ->
        Map.put(acc, wire_key, to_wire_category(Map.get(normalized, key, %{})))
      end)

    Enum.reduce(@wire_booleans, %{"categories" => categories}, fn {wire_key, key}, acc ->
      Map.put(acc, wire_key, Map.get(normalized, key, true))
    end)
  end

  defp wire_shaped?(updates) do
    Map.has_key?(updates, "categories") or
      Enum.any?(Map.keys(@wire_booleans), &Map.has_key?(updates, &1))
  end

  defp from_wire_category(settings) do
    settings
    |> Map.take(["enabled", "preview"])
    |> then(fn taken ->
      case Map.fetch(settings, "sound") do
        {:ok, true} -> Map.put(taken, "sound", @default_sound)
        {:ok, false} -> Map.put(taken, "sound", nil)
        {:ok, value} when is_binary(value) or is_nil(value) -> Map.put(taken, "sound", value)
        _ -> taken
      end
    end)
  end

  defp to_wire_category(settings) do
    %{
      "enabled" => Map.get(settings, "enabled", true),
      "preview" => Map.get(settings, "preview", true),
      "sound" => Map.get(settings, "sound") not in [nil, ""]
    }
  end

  def normalize(preferences) when is_map(preferences) do
    Enum.reduce(@categories, normalize_booleans(preferences), fn category, normalized ->
      stored = Map.get(preferences, category)

      category_settings =
        if is_map(stored) do
          @default_category_settings
          |> maybe_put_fetched("enabled", stored, &is_boolean/1)
          |> maybe_put_fetched("sound", stored, &valid_sound?/1)
          |> maybe_put_fetched("preview", stored, &is_boolean/1)
        else
          @default_category_settings
        end

      Map.put(normalized, category, category_settings)
    end)
  end

  def normalize(_preferences), do: @default_preferences

  def validate_update(updates) when is_map(updates) do
    updates = stringify_keys(updates)

    case update_errors(updates) do
      [] -> {:ok, updates}
      errors -> {:error, error_changeset(errors)}
    end
  end

  def validate_update(_updates),
    do: {:error, error_changeset(["preferences must be an object"])}

  def changeset(notification_preference, attrs) do
    notification_preference
    |> cast(attrs, [:user_id, :preferences])
    |> validate_required([:user_id, :preferences])
    |> validate_change(:preferences, fn :preferences, preferences ->
      validate_complete_preferences(preferences)
    end)
    |> unique_constraint(:user_id)
  end

  defp validate_complete_preferences(preferences) when is_map(preferences) do
    errors = update_errors(preferences) ++ complete_category_errors(preferences)
    missing = (@categories ++ @boolean_keys) -- Map.keys(preferences)

    case missing do
      [] ->
        Enum.map(errors, &{:preferences, &1})

      keys ->
        Enum.map(
          errors ++ ["missing required keys: #{Enum.join(keys, ", ")}"],
          &{:preferences, &1}
        )
    end
  end

  defp validate_complete_preferences(_), do: [preferences: "must be an object"]

  defp complete_category_errors(preferences) do
    Enum.flat_map(@categories, fn category ->
      case Map.get(preferences, category) do
        settings when is_map(settings) ->
          case @category_keys -- Map.keys(settings) do
            [] -> []
            keys -> ["#{category} is missing required keys: #{Enum.join(keys, ", ")}"]
          end

        _other ->
          []
      end
    end)
  end

  defp update_errors(updates) do
    allowed = @categories ++ @boolean_keys

    unknown_errors =
      case Map.keys(updates) -- allowed do
        [] -> []
        keys -> ["contains unsupported keys: #{Enum.join(keys, ", ")}"]
      end

    boolean_errors =
      Enum.flat_map(@boolean_keys, fn key ->
        case Map.fetch(updates, key) do
          :error -> []
          {:ok, value} when is_boolean(value) -> []
          {:ok, _value} -> ["#{key} must be a boolean"]
        end
      end)

    unknown_errors ++ boolean_errors ++ category_errors(updates)
  end

  defp category_errors(updates) do
    Enum.flat_map(@categories, fn category ->
      case Map.fetch(updates, category) do
        :error -> []
        {:ok, settings} -> validate_category(category, settings)
      end
    end)
  end

  defp validate_category(category, settings) when is_map(settings) do
    unknown_errors =
      case Map.keys(settings) -- @category_keys do
        [] -> []
        keys -> ["#{category} contains unsupported keys: #{Enum.join(keys, ", ")}"]
      end

    unknown_errors ++
      validate_boolean_setting(category, settings, "enabled") ++
      validate_sound_setting(category, settings) ++
      validate_boolean_setting(category, settings, "preview")
  end

  defp validate_category(category, _settings), do: ["#{category} must be an object"]

  defp validate_boolean_setting(category, settings, key) do
    case Map.fetch(settings, key) do
      :error -> []
      {:ok, value} when is_boolean(value) -> []
      {:ok, _value} -> ["#{category}.#{key} must be a boolean"]
    end
  end

  defp validate_sound_setting(category, settings) do
    case Map.fetch(settings, "sound") do
      :error -> []
      {:ok, value} when is_binary(value) or is_nil(value) -> []
      {:ok, _value} -> ["#{category}.sound must be a string or null"]
    end
  end

  defp normalize_booleans(preferences) do
    Enum.reduce(@boolean_keys, @default_preferences, fn key, normalized ->
      maybe_put_valid(normalized, key, Map.get(preferences, key), &is_boolean/1)
    end)
  end

  defp maybe_put_valid(map, key, value, validator) do
    if validator.(value), do: Map.put(map, key, value), else: map
  end

  defp maybe_put_fetched(map, key, source, validator) do
    case Map.fetch(source, key) do
      {:ok, value} -> maybe_put_valid(map, key, value, validator)
      :error -> map
    end
  end

  defp valid_sound?(value), do: is_binary(value) or is_nil(value)

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)}
    end)
  end

  defp error_changeset(messages) do
    Enum.reduce(messages, change(%__MODULE__{}), fn message, changeset ->
      add_error(changeset, :preferences, message)
    end)
  end
end
