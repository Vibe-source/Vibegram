defmodule Vibe.AI.GroupAgent do
  @moduledoc """
  AI Agent for group/channel chats.
  """

  require Logger

  alias Vibe.Chat.{GroupAgent, GroupAgentMemory, GroupAgentDocument, AgentMessageCrypto}
  alias Vibe.Notifications
  alias Vibe.Repo

  @claude_api "https://api.anthropic.com/v1/messages"
  @claude_model "claude-haiku-4-5-20251001"

  # Well-known UUID for the Vibe AI agent virtual user
  @agent_user_id "00000000-0000-0000-0000-000000000001"
  @agent_username "vibe_ai_agent_0001"

  # Memory thresholds
  @compaction_threshold 50
  @keep_recent_count 10
  @context_message_limit 30
  @uploads_dir "/app/uploads"
  @agent_docs_dir "agent-docs"
  @max_agent_document_bytes 1_000_000
  @max_claude_tool_depth 8
  @max_tool_attempts 3
  @always_enabled_tools ["pin_message"]

  @default_system_prompt """
  You are Vibe AI, a helpful assistant in this group chat.
  Be concise, practical, and context-aware.
  """

  # Tools available to group agents
  @tools [
    %{
      name: "search_google",
      description:
        "Search the web. Returns real source URLs with titles, snippets, relevance scores " <>
          "and publication dates. This FINDS sources; it does not read them — use read_url " <>
          "before relying on a result's specifics. Call it more than once when one query " <>
          "cannot cover the question.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"},
          max_results: %{type: "integer", description: "How many results. Default 6, max 12."},
          topic: %{
            type: "string",
            enum: ["general", "news", "finance"],
            description: "Search index. \"news\" for current events."
          },
          time_range: %{
            type: "string",
            enum: ["day", "week", "month", "year"],
            description: "Only results published within this window."
          }
        },
        required: ["query"]
      }
    },
    %{
      name: "read_url",
      description:
        "Read the actual text of one or more pages found with search_google (or pasted by a " <>
          "user). Use it before stating specifics — numbers, dates, versions, prices, quotes " <>
          "— that you only saw in a snippet.",
      input_schema: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "The page to read."},
          urls: %{
            type: "array",
            items: %{type: "string"},
            description: "Up to 3 pages in one call. Prefer this over 3 separate calls."
          }
        },
        required: []
      }
    },
    %{
      name: "analyze_image",
      description:
        "Analyze an image URL. Can describe contents, read text (OCR), identify objects.",
      input_schema: %{
        type: "object",
        properties: %{
          image_url: %{type: "string", description: "URL of the image to analyze"},
          task: %{
            type: "string",
            description: "What to do: describe, ocr, identify, or custom question"
          }
        },
        required: ["image_url"]
      }
    },
    %{
      name: "analyze_document",
      description:
        "Analyze a document (PDF, text). Extract information, summarize, or answer questions.",
      input_schema: %{
        type: "object",
        properties: %{
          document_url: %{type: "string", description: "URL of the document"},
          task: %{
            type: "string",
            description: "What to do: summarize, extract_key_points, answer_question"
          },
          question: %{
            type: "string",
            description: "Optional specific question about the document"
          }
        },
        required: ["document_url", "task"]
      }
    },
    %{
      name: "create_document",
      description:
        "Create or edit a formatted document OR editable spreadsheet file scoped to this group. For spreadsheet requests, default to format xlsx (Excel) unless user explicitly asks for csv.",
      input_schema: %{
        type: "object",
        properties: %{
          title: %{type: "string", description: "Document title"},
          body: %{type: "string", description: "Document main content"},
          format: %{
            type: "string",
            enum: [
              "markdown",
              "plain_text",
              "html",
              "json",
              "csv",
              "excel",
              "xlsx",
              "spreadsheet",
              "google_sheet"
            ],
            description:
              "Output document format. Use xlsx/excel/spreadsheet/google_sheet by default for editable table files; use csv only when explicitly requested."
          },
          sections: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional section headings to structure the document"
          },
          columns: %{
            type: "array",
            items: %{type: "string"},
            description: "For spreadsheet output: ordered column headers."
          },
          rows: %{
            type: "array",
            items: %{
              oneOf: [
                %{type: "array", items: %{type: "string"}},
                %{type: "object"}
              ]
            },
            description:
              "For spreadsheet output: row data. Can be arrays aligned to columns, or objects keyed by column name."
          },
          operation: %{
            type: "string",
            enum: ["create_new", "edit_current", "append_rows", "replace_rows", "revert_last"],
            description:
              "Spreadsheet edit operation. Use edit_current/append_rows for ongoing updates; use create_new only when user explicitly asks for a new file."
          }
        },
        required: ["title", "body"]
      }
    },
    %{
      name: "find_rows",
      description:
        "Search the current spreadsheet for rows matching a query. Returns matching rows with their 1-based index. Use this before edit_rows or delete_rows to locate specific rows.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Text to search for across row values (case-insensitive)"
          },
          column: %{
            type: "string",
            description: "Optional: restrict search to a specific column name"
          },
          limit: %{type: "integer", description: "Max rows to return (default 20)"}
        },
        required: ["query"]
      }
    },
    %{
      name: "edit_rows",
      description:
        "Edit specific rows in the current spreadsheet by row index. Use find_rows first to get the correct indices. Only send the columns you want to change.",
      input_schema: %{
        type: "object",
        properties: %{
          edits: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                row_index: %{
                  type: "integer",
                  description: "1-based row index (from find_rows results)"
                },
                values: %{
                  type: "object",
                  description: "Column name → new value for each cell to change"
                }
              },
              required: ["row_index", "values"]
            },
            description: "List of row edits to apply"
          }
        },
        required: ["edits"]
      }
    },
    %{
      name: "delete_rows",
      description:
        "Delete specific rows from the current spreadsheet by their 1-based index. Use find_rows first to locate rows.",
      input_schema: %{
        type: "object",
        properties: %{
          row_indices: %{
            type: "array",
            items: %{type: "integer"},
            description: "1-based row indices to delete"
          }
        },
        required: ["row_indices"]
      }
    },
    %{
      name: "export_rows",
      description:
        "Export rows from the current spreadsheet as a styled PDF (default) or PNG file. Can filter by search query or specific row indices. Use this when the user wants to send, share, or print specific records.",
      input_schema: %{
        type: "object",
        properties: %{
          title: %{type: "string", description: "Title for the exported document"},
          query: %{type: "string", description: "Optional: search text to filter rows"},
          row_indices: %{
            type: "array",
            items: %{type: "integer"},
            description: "Optional: specific 1-based row indices to export"
          },
          format: %{
            type: "string",
            enum: ["pdf", "png"],
            description: "Export format. Default is pdf."
          }
        },
        required: ["title"]
      }
    },
    %{
      name: "delete_document",
      description:
        "Delete/remove the current spreadsheet or document from this group chat. Use when the user asks to delete, remove, or clear the current file.",
      input_schema: %{
        type: "object",
        properties: %{
          confirm: %{type: "boolean", description: "Must be true to confirm deletion"}
        },
        required: ["confirm"]
      }
    },
    %{
      name: "pin_message",
      description:
        "Pin or unpin a message/file in this chat. Use when the user says pin it, pin this file, or unpin.",
      input_schema: %{
        type: "object",
        properties: %{
          message_id: %{
            type: "string",
            description: "Optional specific message UUID to pin/unpin"
          },
          target: %{
            type: "string",
            enum: ["latest_agent_file", "latest_file", "latest_message"],
            description:
              "Fallback target when message_id is omitted. Use latest_agent_file for 'pin it' after agent creates a file."
          },
          pinned: %{type: "boolean", description: "true=pin (default), false=unpin"}
        }
      }
    }
  ]

  @doc """
  Returns the well-known agent user ID constant.
  """
  def agent_user_id, do: @agent_user_id

  @doc """
  Returns default system prompt text for group agents.
  """
  def default_system_prompt, do: @default_system_prompt

  @doc """
  Returns all available tool definitions for the group agent.
  """
  def available_tools, do: @tools

  @doc """
  Returns all available tool names.
  """
  def available_tool_names, do: Enum.map(@tools, & &1.name)

  @doc """
  Returns the tool set that can be used by standalone agents.
  Standalone agents reuse document and analysis tools but cannot pin chat messages.
  """
  def standalone_available_tools do
    Enum.reject(@tools, &(&1.name == "pin_message"))
  end

  @doc """
  Returns standalone-capable tool names.
  """
  def standalone_tool_names, do: Enum.map(standalone_available_tools(), & &1.name)

  @doc """
  Normalize enabled tools list coming from API input/database.
  """
  def normalize_enabled_tools(raw_tools) do
    available = available_tool_names()
    allowed = MapSet.new(available)
    mandatory = Enum.filter(@always_enabled_tools, &MapSet.member?(allowed, &1))

    normalized =
      raw_tools
      |> normalize_tools_input()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(allowed, &1))

    selected = if normalized == [], do: available, else: normalized
    selected_set = MapSet.new(selected ++ mandatory) |> grant_reading_to_searchers()
    Enum.filter(available, &MapSet.member?(selected_set, &1))
  end

  defp grant_reading_to_searchers(selected_set) do
    if MapSet.member?(selected_set, "search_google") do
      MapSet.put(selected_set, "read_url")
    else
      selected_set
    end
  end

  @doc """
  Executes a standalone-safe group-agent tool. Chat-scoped tools require a vibe chat id.
  """
  def execute_standalone_tool(name, input, user_id, chat_id) do
    cond do
      name == "pin_message" ->
        %{ok: false, tool: name, error: "pin_message is not available for standalone agents"}

      name not in standalone_tool_names() ->
        %{ok: false, tool: name, error: "Unknown standalone tool: #{name}"}

      name in ~w[create_document find_rows edit_rows delete_rows export_rows delete_document] and
          not valid_chat_id?(chat_id) ->
        %{ok: false, tool: name, error: "This tool requires vibeChatId and an attached Vibe chat"}

      true ->
        execute_tool_with_recovery(name, input, user_id, chat_id, 1)
    end
  end

  defp valid_chat_id?(chat_id) when is_binary(chat_id), do: String.trim(chat_id) != ""
  defp valid_chat_id?(_chat_id), do: false

  @doc """
  Generate an enhanced system prompt from short admin input.
  Uses LLM when available and falls back to deterministic prompt text.
  """
  def generate_system_prompt(user_input, enabled_tools \\ nil) do
    trimmed_input =
      user_input
      |> to_string()
      |> String.trim()

    if trimmed_input == "" do
      {:error, :empty_input}
    else
      normalized_tools = normalize_enabled_tools(enabled_tools)
      prompt = build_prompt_generation_instruction(trimmed_input, normalized_tools)

      case Vibe.AI.Agent.quick_completion(prompt) do
        {:ok, generated} ->
          final_prompt = normalize_generated_prompt(generated, trimmed_input)
          {:ok, final_prompt}

        {:error, _reason} ->
          {:ok, fallback_generated_prompt(trimmed_input)}
      end
    end
  end

  @doc """
  Handle an @vibe mention in a group chat.
  Loads agent config, builds context with memory, calls Claude, and broadcasts the response.
  """
  def handle_mention(chat_id, user_message, user_id, metadata \\ %{}) do
    Logger.info(
      "[GroupAgent] handle_mention called chat_id=#{chat_id} user_id=#{user_id} msg_len=#{String.length(user_message)}"
    )

    case GroupAgent.get_enabled_by_chat(chat_id, acting_user_id: user_id) do
      nil ->
        Logger.info("[GroupAgent] No enabled agent for chat #{chat_id}")
        {:error, :no_agent}

      agent_config ->
        process_mention(chat_id, agent_config, user_message, user_id, metadata)
    end
  end

  defp process_mention(chat_id, agent_config, user_message, user_id, metadata) do
    enabled_tools = normalize_enabled_tools(Map.get(agent_config, :enabled_tools))

    {:ok, memory} = GroupAgentMemory.get_or_create(chat_id, acting_user_id: user_id)

    Logger.info(
      "[GroupAgent] Memory loaded for #{chat_id}: #{length(memory.messages)} messages, summary=#{if memory.summary, do: "yes", else: "no"}"
    )

    group_document_context = build_group_document_context(chat_id)

    system_prompt =
      build_system_prompt(agent_config, memory, enabled_tools, group_document_context)

    messages = build_messages(memory, user_message, metadata)

    broadcast_agent_progress(
      chat_id,
      "Typing...",
      "react_plan",
      "running",
      %{"stage" => "typing"}
    )

    Logger.info(
      "[GroupAgent] Calling Claude for #{chat_id}: #{length(messages)} messages, system_prompt_len=#{String.length(system_prompt)}"
    )

    case call_claude(messages, system_prompt, user_id, enabled_tools, chat_id) do
      {:ok, %{text: response_text, attachment: tool_attachment}} ->
        fallback_result =
          maybe_attach_spreadsheet_fallback(
            chat_id,
            user_message,
            response_text,
            enabled_tools,
            user_id,
            tool_attachment
          )

        response = fallback_result.text
        resolved_attachment = fallback_result.attachment

        attachment_summary = summarize_attachments_for_memory(metadata)

        stored_user_content =
          user_message
          |> String.trim()
          |> append_attachment_summary_for_storage(attachment_summary)

        GroupAgentMemory.append_message(
          chat_id,
          %{
            "role" => "user",
            "content" => stored_user_content,
            "user_id" => user_id
          }, acting_user_id: user_id)

        GroupAgentMemory.append_message(
          chat_id,
          %{
            "role" => "assistant",
            "content" => response
          }, acting_user_id: user_id)

        maybe_compact(chat_id, user_id)

        broadcast_agent_progress(
          chat_id,
          "Finalizing...",
          "react_plan",
          "running",
          %{"stage" => "finalizing"}
        )

        broadcast_agent_message(
          chat_id,
          agent_config,
          response,
          user_id,
          metadata,
          resolved_attachment
        )

        broadcast_agent_progress(chat_id, "", "react_plan", "complete", %{"stage" => "completed"})

        {:ok, response}

      {:error, reason} ->
        Logger.error("[GroupAgent] Claude error for chat #{chat_id}: #{inspect(reason)}")

        broadcast_agent_progress(
          chat_id,
          "Finalizing...",
          "react_plan",
          "error",
          %{"stage" => "failed"}
        )

        broadcast_agent_message(
          chat_id,
          agent_config,
          "Sorry, I encountered an error processing your request. Please try again.",
          user_id,
          metadata
        )

        {:error, reason}
    end
  end

  defp build_system_prompt(agent_config, memory, enabled_tools, group_document_context) do
    base_system_prompt =
      (agent_config.system_prompt || @default_system_prompt)
      |> to_string()
      |> String.trim()

    tool_descriptions =
      @tools
      |> Enum.filter(&(&1.name in enabled_tools))
      |> Enum.map(fn tool -> "- #{tool.name}: #{tool.description}" end)
      |> Enum.join("\n")

    base_prompt = """
    #{base_system_prompt}

    #{Vibe.AI.AgenticPolicy.prompt_guidance(enabled_tools)}

    IMPORTANT RULES:

    CONVERSATION:
    - You are #{agent_config.name}, an AI assistant in this group chat.
    - Keep responses concise and relevant — this is mobile chat.
    - ALWAYS reply in the same language the user wrote in. If they write in Persian, reply in Persian. If Arabic, reply in Arabic. Match their language exactly.
    - Address users naturally, referring to the group context.
    - You can reference previous conversations from your memory.
    - Use a direct ReAct workflow for every request: understand task -> inspect state -> execute -> verify -> respond.
    - You may send a short status sentence before tool calls when useful (example: "Let me check the current rows first.").
    - Only use tools that are enabled for this group.
    - If attachments are provided in the current message context, use them.
    - CRITICAL: The user's LATEST message is the highest priority. If the user specifies column order, column names, or layout structure, follow their request EXACTLY — do NOT copy column structure from previous documents in the conversation history. Always obey the latest instruction.

    REACT EXECUTION LOOP (MANDATORY):
    - Step 1 (Task Check): Before any action, identify the exact task and what must change.
    - Step 2 (Inspect): For updates/deletes, inspect current state first (find_rows and/or current document context).
    - Step 3 (Execute): Apply the smallest safe tool action that performs the requested change.
    - Step 4 (Recover): If a tool fails or returns no-op, diagnose why, adjust input, and retry.
    - Step 5 (Verify): Re-check affected rows/state before final response.
    - Use up to 3 recovery cycles. If still blocked, ask one concise clarifying question.
    - Never claim "done" without verification evidence.
    - FINAL TOOL-EVIDENCE GATE (MANDATORY): before final response, verify whether this turn has a successful file-producing tool result (`ok=true` and `file_url`/`download_path`).
    - If the user requested send/resend/export/attach and the gate fails, you MUST keep using tools (or report explicit failure) and you MUST NOT claim attachment.

    DATA INTERPRETATION:
    - When a user describes data in natural language, carefully parse their intent and extract structured values.
    - Convert messy descriptions into clean, normalized cell values (e.g. "٣٠/٠٠٠ درهم" → "30,000").
    - Calculate totals, balances, and summaries yourself — do not copy the user's arithmetic verbatim.
    - If the user's request is ambiguous, ask a brief clarifying question before creating the document.
    - PERSIAN/ARABIC NUMBER PARSING: Users often write amounts in informal Persian/Arabic. You MUST correctly parse these:
      * "هزار" (hezar) = thousand (×1,000). E.g. "700 هزار" = 700,000 | "پنجاه هزار" = 50,000
      * "میلیون" / "ملیون" (milion) = million (×1,000,000). E.g. "یک میلیون" = 1,000,000 | "2 میلیون" = 2,000,000
      * "میلیارد" (miliard) = billion (×1,000,000,000)
      * "و نیم" (va nim) = +half. E.g. "دو و نیم میلیون" = 2,500,000 | "یک و نیم هزار" = 1,500
      * "تومن" / "تومان" / "تومون" (toman) = currency unit — keep as-is or convert if context is clear
      * "درهم" (dirham) = currency unit
      * Persian digits: ۰۱۲۳۴۵۶۷۸۹ map to 0123456789. Arabic digits: ٠١٢٣٤٥٦٧٨٩ also map to 0123456789.
      * Slash notation: "700/000" = 700,000 | "1/500/000" = 1,500,000
      * Word numbers: "یک"=1, "دو"=2, "سه"=3, "چهار"=4, "پنج"=5, "شش"=6, "هفت"=7, "هشت"=8, "نه"=9, "ده"=10, "بیست"=20, "سی"=30, "چهل"=40, "پنجاه"=50, "صد"=100
    - When writing numbers into spreadsheet cells, use plain numeric format with comma separators (e.g. "2,500,000") — do NOT write the Persian word form.

    - CRITICAL ACCURACY: When computing totals/sums, calculate ONLY from the data the user provided. Do NOT invent, duplicate, or add extra rows. Double-check every multiplication (weight × price) and sum before outputting. If a number looks wrong, recompute it.
    - STRICT COLUMNS: Create EXACTLY the columns the user specified. If they say 4 columns, create 4 columns. Do not add helper columns, word-form columns, or extra descriptive columns. NEVER add a "جمع به حروف" (amount in words) column.

    DOCUMENT & SPREADSHEET:
    - For document/file requests, generate professional outputs with clean structure and naming.
    - When a tool creates/updates a file, respond naturally and state that the file is attached (do not paste raw URLs).
    - ATTACHMENT TRUTH RULE (CRITICAL): ONLY say a file/image is attached if the tool result in THIS turn includes `ok=true` and a non-empty `file_url`/`download_path`.
    - If no tool result contains a file URL, NEVER say "attached", "sent", "ضمیمه", or "پیوست".
    - For send/resend/export requests, do not finish with text-only output. You MUST call the appropriate file-producing tool first, then respond.
    - If the tool fails or returns without file_url, retry with corrected inputs. If still no file URL, explicitly say attachment failed and ask for retry; do not claim success.
    - Do NOT treat previous-turn files as newly attached. Only the current turn's successful tool output counts.
    - Never claim you cannot create/edit spreadsheet files when create_document is enabled.
    - The generated XLSX files already have professional styling (dark headers, alternating row colors, auto-sized columns, frozen header, auto-filters, RTL layout) — do NOT add any formatting hints, borders, colors, or decorators in cell text values. Keep cell data clean and plain.
    - Spreadsheet behavior is stateful per group chat. Default: edit the current spreadsheet.
    - Use operation=create_new ONLY when user explicitly asks for a completely NEW file/from-scratch sheet.
    - CRITICAL BLANK/RAW FILE: When the user says "new and raw/blank/empty" (خام, خالی, جدید و خام, فايل خام, blank, empty, template), create the spreadsheet with ONLY the column headers and ZERO data rows (rows=[]). Do NOT fill in any data from conversation history or memory. The user wants a clean template to fill in themselves.
    - For adding data, prefer operation=append_rows.
    - For corrections, prefer operation=edit_current or replace_rows.
    - If user asks to undo/revert, use operation=revert_last.
    - If user asks for Excel/sheet/spreadsheet/table with rows/columns, call create_document with format xlsx unless user explicitly asks for csv.
    - CRITICAL: When the user asks to "update the design", "reorder columns", "change the layout", "restructure", "remove a column" (ستون/رديف حذف كن), "merge columns" (ادغام كن), or any structural change to the spreadsheet, use create_document with operation=replace_rows. Read the current data from the document context, restructure it, and send the updated columns + rows. Do NOT just reply with text — you MUST call the tool.
    - MANDATORY TOOL CALLS: When the user asks ANY request that modifies the spreadsheet (edit, add, remove, restructure, merge, update, fix, resend), you MUST call a tool (create_document, edit_rows, delete_rows, etc.). NEVER respond with just a text message saying "done" or "I will do it" without actually calling a tool. This includes Persian requests like "درست کن" (fix it), "مجدد بفرست" (resend), "دوباره بساز" (rebuild), "فایل رو بفرست" (send the file), "اصلاح کن" (correct it). ALWAYS call the tool.
    - SEND/RESEND RULE: For "send/resend file" requests ("بفرست", "مجدد بفرست", "دوباره بفرست"), always call a file-producing tool in the same turn:
      * xlsx/csv requests -> create_document
      * png/pdf/image requests -> export_rows
      Then verify `file_url` exists before final reply.
    - If send/resend request has no successful file-producing tool result, final response must explicitly state failure to attach and request retry; never claim "sent/attached".

    DELETING DOCUMENTS:
    - When the user says "delete the file", "remove the document", "فایل رو حذف کن", "پاک کن", or "clear the spreadsheet", use the delete_document tool with confirm=true.
    - After deletion, confirm to the user that the file has been removed.

    PINNING FILES/MESSAGES:
    - When the user says "pin it", "pin this", "pin this file", "سنجاقش کن", "پین کن", or asks to unpin, use pin_message.
    - For "pin it" right after a file is created/exported, default to target=latest_agent_file.
    - If user specifies a specific message, pass message_id.
    - After pin/unpin, confirm exactly what was pinned/unpinned.
    - STRICT CONFIRMATION GATE: you must not claim "pinned/unpinned" unless pin_message returned ok=true in this turn.

    ROW-LEVEL EDITING:
    - For targeted edits (changing a few cells or rows), use find_rows to locate the row first, then edit_rows with the row index. Do NOT resend all rows via create_document for small changes.
    - For column removal, column merging, column reordering, or any structural change to the table shape, use create_document with operation=replace_rows. Include ALL existing rows with the new column structure.
    - Use delete_rows to remove specific data rows by index. Always use find_rows first to confirm the correct row.
    - When the user says "change X to Y", "fix row N", or "update the amount for John", use find_rows + edit_rows.
    - When the user says "حذف كن" (delete), "تغيير بده" (change), "اضافه كن" (add), "ادغام كن" (merge) — ALWAYS call the appropriate tool immediately.
    - If the user challenges correctness (e.g., "wrong file", "check again", "you made a mistake"), re-check the current file before defending your answer. Use tools to verify, then either fix the file or clearly confirm why it is already correct.

    EXPORTING & SHARING:
    - CRITICAL: When the user asks for a PNG, PDF, image, screenshot, or photo of their spreadsheet/data, you MUST use the export_rows tool — NEVER use create_document for this. create_document can only produce xlsx/csv/text files, NOT images or PDFs.
    - When the user says "give me a PNG", "send as image", "عکس بده", "تصویر بفرست", "فایل PNG بده", "export as pdf", or similar — always use export_rows with the appropriate format (png or pdf).
    - export_rows can filter by search query or specific row indices. If no filter is specified, it exports all rows.
    - Default export format is PDF unless the user explicitly asks for an image/PNG/picture.
    - Do not send the raw XLSX/CSV file when the user wants to share, print, or visualize data — use export_rows instead.

    SPREADSHEET QUALITY & RTL:
      * RTL COLUMN ORDER: The XLSX is rendered right-to-left. The FIRST column in the columns array appears on the RIGHT side of the spreadsheet. So order columns from most important (right/first) to least important (left/last). For example: [شماره کانتینر, فرستنده, کالا, تعداد, گیرنده/تماس, یادداشت].
      * Use clear, professional column headers in a stable order.
      * Keep every row aligned to the column count (no missing/extra cells).
      * Normalize noisy values (trim spaces, remove filler text, keep wording consistent).
      * Prefer normalized date and number representations (use digits, not words).
      * Each data item must appear exactly once — never duplicate rows.
      * Keep notes/comments in a dedicated column; never mix them into data value cells.
      * Separate summary or total rows clearly from data rows (place them last).
      * Do NOT put emoji, symbols, or decorative characters in data cells — the renderer handles all visual styling.
      * NEVER put greeting text or any religious/greeting phrases as a data row. If the user includes such text, put it in the document title instead.
      * NEVER duplicate the column headers as the first data row. The renderer already adds a styled header row — do NOT repeat it in the rows array.
      * Keep column count reasonable (5-7 columns max). Merge related info into single columns (e.g., "گیرنده/تماس" instead of separate "گیرنده" and "شماره تماس" columns) to keep the table compact.

    COMPLETION RESPONSE:
    - After successful execution, confirm completion explicitly and end with "Done."
    - For updates, include what changed and before -> after values when tool output provides them.
    - Include one verification line (example: "You can confirm by checking the updated file.").
    - Avoid rigid canned templates; keep the response natural and task-specific.
    - NEVER include attachment wording unless the final turn contains successful file tool evidence.

    ENABLED TOOLS:
    #{if tool_descriptions == "", do: "- none", else: tool_descriptions}

    CURRENT GROUP DOCUMENT CONTEXT:
    #{group_document_context}
    """

    case memory.summary do
      nil ->
        base_prompt

      "" ->
        base_prompt

      summary ->
        base_prompt <> "\n\nConversation Memory (summary of earlier interactions):\n#{summary}\n"
    end
  end

  defp build_group_document_context(chat_id) do
    latest_document = GroupAgentDocument.get_current(chat_id)
    current_spreadsheet = resolve_current_spreadsheet_document(chat_id, latest_document)

    case current_spreadsheet do
      nil ->
        "No active spreadsheet file for this group yet."

      spreadsheet ->
        column_list = List.wrap(spreadsheet.columns)

        columns =
          column_list
          |> Enum.join(", ")
          |> default_if_blank("(none)")

        recent_versions =
          chat_id
          |> GroupAgentDocument.list_recent(3)
          |> Enum.map_join("\n", fn doc ->
            "- v#{doc.version} (#{doc.change_type}) #{doc.title} => #{doc.relative_url}"
          end)
          |> default_if_blank("- none")

        row_preview =
          case read_agent_document_file(spreadsheet) do
            {:ok, csv} ->
              {_cols, rows} = parse_csv_content(csv)

              rows
              |> Enum.with_index(1)
              |> Enum.take(5)
              |> Enum.map_join("\n", fn {row, idx} ->
                "  #{idx}: #{Enum.join(row, " | ")}"
              end)
              |> default_if_blank("  (empty)")

            _ ->
              "  (unavailable)"
          end

        latest_generated_file =
          case latest_document do
            %GroupAgentDocument{id: latest_id} when latest_id != spreadsheet.id ->
              "- latest generated file: #{latest_document.title} (#{latest_document.format}) => #{latest_document.file_url}"

            _ ->
              "- latest generated file: same as editable spreadsheet"
          end

        """
        Current editable spreadsheet:
        - version: #{spreadsheet.version}
        - title: #{spreadsheet.title}
        - format: #{spreadsheet.format}
        - rows: #{spreadsheet.row_count}
        - columns: #{columns}
        - file_url: #{spreadsheet.file_url}
        - preview (first 5 rows):
        #{row_preview}
        #{latest_generated_file}

        Recent versions:
        #{recent_versions}
        """
        |> String.trim()
    end
  end

  defp resolve_current_spreadsheet_document(chat_id, %GroupAgentDocument{} = current_document) do
    if spreadsheet_document_format?(current_document.format) do
      current_document
    else
      latest_spreadsheet_document(chat_id)
    end
  end

  defp resolve_current_spreadsheet_document(chat_id, _), do: latest_spreadsheet_document(chat_id)

  defp latest_spreadsheet_document(chat_id) do
    chat_id
    |> GroupAgentDocument.list_recent(50)
    |> Enum.find(fn document -> spreadsheet_document_format?(document.format) end)
  end

  defp spreadsheet_document_format?(format) do
    normalized =
      format
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized in ["csv", "xlsx", "excel", "spreadsheet", "google_sheet", "google_sheets"]
  end

  defp build_messages(memory, current_message, metadata) do
    recent_messages =
      memory.messages
      |> Enum.take(-@context_message_limit)
      |> Enum.map(fn msg ->
        %{
          role: msg["role"] || "user",
          content: msg["content"] || ""
        }
      end)
      |> Enum.filter(fn msg -> msg.content != "" end)

    image_urls = normalize_url_list(Map.get(metadata, "image_urls", []))
    document_urls = normalize_url_list(Map.get(metadata, "document_urls", []))

    attachment_context = build_attachment_context(image_urls, document_urls)
    merged_message_text = append_attachment_context(current_message, attachment_context)

    current_content =
      if Enum.empty?(image_urls) do
        merged_message_text
      else
        image_blocks =
          Enum.map(image_urls, fn url ->
            %{type: "image", source: %{type: "url", url: url}}
          end)

        image_blocks ++ [%{type: "text", text: merged_message_text}]
      end

    recent_messages ++ [%{role: "user", content: current_content}]
  end

  defp call_claude(messages, system_prompt, user_id, enabled_tools, chat_id) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY")

    Logger.info(
      "[GroupAgent] API key configured: #{if api_key, do: "yes (#{String.length(api_key)} chars)", else: "NO - MISSING"}"
    )

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not configured"}
    else
      enabled_tool_definitions =
        @tools
        |> Enum.filter(&(&1.name in enabled_tools))

      call_claude_with_tools(
        messages,
        system_prompt,
        api_key,
        0,
        user_id,
        enabled_tools,
        enabled_tool_definitions,
        chat_id,
        nil,
        %{pin_message_called: false, pin_message_ok: false}
      )
    end
  end

  defp call_claude_with_tools(
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions,
         chat_id,
         pending_attachment,
         tool_audit
       ) do
    if depth > @max_claude_tool_depth do
      {:error, "Max tool depth reached (#{@max_claude_tool_depth})"}
    else
      body =
        Jason.encode!(%{
          model: @claude_model,
          max_tokens: 4096,
          system: system_prompt,
          tools: enabled_tool_definitions,
          messages: messages
        })

      headers = [
        {"Content-Type", "application/json"},
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]

      request = Finch.build(:post, @claude_api, headers, body)

      dispatch = fn parsed ->
        dispatch_provider_response(
          parsed,
          messages,
          system_prompt,
          api_key,
          depth,
          user_id,
          enabled_tools,
          enabled_tool_definitions,
          chat_id,
          pending_attachment,
          tool_audit
        )
      end

      case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          case Jason.decode(resp_body) do
            {:ok, parsed} when is_map(parsed) ->
              dispatch.(parsed)

            other ->
              Logger.error("[GroupAgent] Failed to parse Claude response: #{inspect(other)}")
              {:error, "Failed to parse Claude response"}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error(
            "[GroupAgent] Claude API error: status=#{status} body=#{String.slice(body, 0..500)}"
          )

          fallback_to_openai(
            messages,
            system_prompt,
            enabled_tool_definitions,
            "API error: #{status}",
            dispatch
          )

        {:error, reason} ->
          fallback_to_openai(
            messages,
            system_prompt,
            enabled_tool_definitions,
            inspect(reason),
            dispatch
          )
      end
    end
  end

  defp fallback_to_openai(messages, system_prompt, tool_definitions, reason, dispatch) do
    Logger.warning("[GroupAgent] Anthropic unavailable (#{reason}); falling back to OpenAI")

    config = %Vibe.AI.AgentRuntime.Config{
      model: @claude_model,
      system_prompt: system_prompt,
      tools: tool_definitions,
      max_tokens: 4096,
      execute_tools: fn _calls, state, _callback -> {[], state} end,
      request_label: "GroupAgent"
    }

    case Vibe.AI.AgentRuntime.anthropic_shaped_openai_completion(messages, config) do
      {:ok, parsed} ->
        dispatch.(parsed)

      {:error, openai_reason} ->
        Logger.error("[GroupAgent] OpenAI fallback also failed: #{inspect(openai_reason)}")
        {:error, reason}
    end
  end

  defp dispatch_provider_response(
         parsed,
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions,
         chat_id,
         pending_attachment,
         tool_audit
       ) do
    content = Map.get(parsed, "content")
    stop_reason = Map.get(parsed, "stop_reason")

    Logger.info("[GroupAgent] Provider response received, stop_reason=#{inspect(stop_reason)}")

    cond do
      not is_list(content) ->
        Logger.error("[GroupAgent] Provider response had no content: #{inspect(parsed)}")
        {:error, "Failed to parse Claude response"}

      stop_reason == "tool_use" ->
        handle_tool_response(
          content,
          messages,
          system_prompt,
          api_key,
          depth,
          user_id,
          enabled_tools,
          enabled_tool_definitions,
          chat_id,
          pending_attachment,
          tool_audit
        )

      true ->
        maybe_force_llm_confirmation(
          messages,
          content,
          extract_text(content),
          system_prompt,
          api_key,
          depth,
          user_id,
          enabled_tools,
          enabled_tool_definitions,
          chat_id,
          pending_attachment,
          tool_audit
        )
    end
  end

  defp handle_tool_response(
         content,
         messages,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions,
         chat_id,
         pending_attachment,
         tool_audit
       ) do
    tool_calls =
      Enum.filter(content, fn
        %{"type" => "tool_use"} -> true
        _ -> false
      end)

    {tool_results, latest_attachment, next_tool_audit} =
      Enum.reduce(tool_calls, {[], pending_attachment, tool_audit}, fn tool,
                                                                       {acc_results,
                                                                        acc_attachment, acc_audit} ->
        result = execute_tool(tool["name"], tool["input"], user_id, enabled_tools, chat_id)
        tool_attachment = extract_tool_attachment(tool["name"], result)
        updated_audit = update_tool_audit(acc_audit, tool["name"], result)

        tool_result = %{
          "type" => "tool_result",
          "tool_use_id" => tool["id"],
          "content" => Jason.encode!(result)
        }

        next_attachment = tool_attachment || acc_attachment
        {[tool_result | acc_results], next_attachment, updated_audit}
      end)

    tool_results = Enum.reverse(tool_results)

    assistant_content =
      Enum.map(content, fn
        %{"type" => "text", "text" => text} ->
          %{type: "text", text: text}

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          %{type: "tool_use", id: id, name: name, input: input}

        other ->
          other
      end)

    new_messages =
      messages ++
        [
          %{role: "assistant", content: assistant_content},
          %{role: "user", content: tool_results}
        ]

    call_claude_with_tools(
      new_messages,
      system_prompt,
      api_key,
      depth + 1,
      user_id,
      enabled_tools,
      enabled_tool_definitions,
      chat_id,
      latest_attachment,
      next_tool_audit
    )
  end

  defp content_blocks_from_claude_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: "text", text: text}

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        %{type: "tool_use", id: id, name: name, input: input}

      other ->
        other
    end)
  end

  defp content_blocks_from_claude_content(_), do: []

  defp maybe_force_llm_confirmation(
         messages,
         content,
         text,
         system_prompt,
         api_key,
         depth,
         user_id,
         enabled_tools,
         enabled_tool_definitions,
         chat_id,
         pending_attachment,
         tool_audit
       ) do
    case llm_confirm_tool_execution(messages, text, tool_audit, api_key) do
      {:ok, :pass} ->
        {:ok, %{text: text, attachment: pending_attachment}}

      {:ok, {:retry, retry_instruction}} ->
        Logger.warning(
          "[GroupAgent] LLM confirmation gate requested retry before final response chat_id=#{chat_id} instruction=#{inspect(retry_instruction)}"
        )

        assistant_content = content_blocks_from_claude_content(content)

        forced_user_check = %{
          role: "user",
          content: [
            %{
              type: "text",
              text: retry_instruction
            }
          ]
        }

        call_claude_with_tools(
          messages ++ [%{role: "assistant", content: assistant_content}, forced_user_check],
          system_prompt,
          api_key,
          depth + 1,
          user_id,
          enabled_tools,
          enabled_tool_definitions,
          chat_id,
          pending_attachment,
          tool_audit
        )

      {:error, reason} ->
        Logger.warning(
          "[GroupAgent] LLM confirmation gate failed chat_id=#{chat_id} reason=#{inspect(reason)}"
        )

        assistant_content = content_blocks_from_claude_content(content)

        forced_user_check = %{
          role: "user",
          content: [
            %{
              type: "text",
              text:
                "SYSTEM CONFIRMATION GATE: verify required tool execution before final response."
            }
          ]
        }

        call_claude_with_tools(
          messages ++ [%{role: "assistant", content: assistant_content}, forced_user_check],
          system_prompt,
          api_key,
          depth + 1,
          user_id,
          enabled_tools,
          enabled_tool_definitions,
          chat_id,
          pending_attachment,
          tool_audit
        )
    end
  end

  defp update_tool_audit(audit, "pin_message", result) when is_map(audit) do
    pin_ok =
      case result do
        %{ok: true} -> true
        %{"ok" => true} -> true
        _ -> false
      end

    audit
    |> Map.put(:pin_message_called, true)
    |> Map.put(:pin_message_ok, Map.get(audit, :pin_message_ok, false) or pin_ok)
  end

  defp update_tool_audit(audit, _tool_name, _result) when is_map(audit), do: audit

  defp update_tool_audit(_audit, _tool_name, _result),
    do: %{pin_message_called: false, pin_message_ok: false}

  defp llm_confirm_tool_execution(messages, draft_response_text, tool_audit, api_key) do
    latest_user_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{role: "user", content: content} -> extract_text_from_message_content(content)
        _ -> nil
      end)
      |> to_string()
      |> String.trim()

    audit_payload = %{
      pin_message_called: Map.get(tool_audit, :pin_message_called, false),
      pin_message_ok: Map.get(tool_audit, :pin_message_ok, false)
    }

    confirmation_prompt = """
    You are a strict execution validator.
    Decide whether this assistant draft is allowed to be sent.

    Rules:
    - Return JSON only (no markdown).
    - Determine from the user request intent whether pin/unpin action is required.
    - If pin/unpin is required, the response is allowed only when pin_message_ok=true.
    - If pin/unpin is not required, allow response.

    Output schema:
    {"allow": boolean, "needs_pin_action": boolean, "retry_instruction": string}

    latest_user_request:
    #{latest_user_text}

    draft_assistant_response:
    #{draft_response_text}

    tool_audit:
    #{Jason.encode!(audit_payload)}
    """

    body =
      Jason.encode!(%{
        model: @claude_model,
        max_tokens: 220,
        system: "Return strict JSON only.",
        messages: [%{role: "user", content: confirmation_prompt}]
      })

    headers = [
      {"Content-Type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    request = Finch.build(:post, @claude_api, headers, body)

    with {:ok, %{status: 200, body: resp_body}} <-
           Finch.request(request, Vibe.Finch, receive_timeout: 15_000),
         {:ok, %{"content" => content}} <- Jason.decode(resp_body),
         raw_text when is_binary(raw_text) <- extract_text(content),
         {:ok, parsed} <- decode_lenient_json(raw_text) do
      allow = Map.get(parsed, "allow") == true
      needs_pin_action = Map.get(parsed, "needs_pin_action") == true
      retry_instruction_raw = Map.get(parsed, "retry_instruction")

      retry_instruction =
        if is_binary(retry_instruction_raw) and String.trim(retry_instruction_raw) != "" do
          String.trim(retry_instruction_raw)
        else
          "SYSTEM CONFIRMATION GATE: Pin/unpin was requested. You must execute pin_message successfully, verify result, then reply."
        end

      Logger.info(
        "[GroupAgent] LLM confirmation result allow=#{allow} needs_pin_action=#{needs_pin_action} pin_message_ok=#{Map.get(tool_audit, :pin_message_ok, false)}"
      )

      if allow do
        {:ok, :pass}
      else
        {:ok, {:retry, retry_instruction}}
      end
    else
      {:ok, %{status: status, body: body}} ->
        {:error, {:confirmation_api_error, status, String.slice(body, 0..220)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:confirmation_parse_error, other}}
    end
  end

  defp decode_lenient_json(raw_text) when is_binary(raw_text) do
    trimmed = raw_text |> String.trim() |> strip_markdown_code_fence()

    case Jason.decode(trimmed) do
      {:ok, parsed} ->
        {:ok, parsed}

      _ ->
        case Regex.run(~r/\{.*\}/s, trimmed) do
          [json_blob] -> Jason.decode(json_blob)
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp decode_lenient_json(_), do: {:error, :invalid_json}

  defp strip_markdown_code_fence(text) when is_binary(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/^```(?:json)?\s*(.*?)\s*```$/s, trimmed, capture: :all_but_first) do
      [inner] -> inner
      _ -> trimmed
    end
  end

  defp extract_text_from_message_content(content) when is_binary(content), do: content

  defp extract_text_from_message_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp extract_text_from_message_content(_), do: nil

  defp execute_tool(name, input, user_id, enabled_tools, chat_id) do
    if name in enabled_tools do
      progress_label = tool_progress_label(name, input)
      running_stage = tool_progress_stage(name, "running")

      broadcast_agent_progress(chat_id, progress_label, name, "running", %{
        "attempt" => 1,
        "stage" => running_stage
      })

      start_time = System.monotonic_time(:millisecond)

      if name == "create_document" do
        raw_cols_count =
          case tool_input_value(input, "columns") do
            columns when is_list(columns) -> length(columns)
            _ -> 0
          end

        raw_rows =
          case input do
            %{"rows" => r} when is_list(r) -> length(r)
            _ -> "none"
          end

        raw_op = tool_input_value(input, "operation")
        raw_body_bytes = tool_input_value(input, "body") |> byte_size()

        Logger.info(
          "[GroupAgent] create_document RAW INPUT: op=#{raw_op} cols_count=#{raw_cols_count} rows_count=#{raw_rows} body=<redacted #{raw_body_bytes} bytes>"
        )
      end

      result = execute_tool_with_recovery(name, input, user_id, chat_id, 1)
      attempts_used = tool_attempt_count(result)

      duration_ms = System.monotonic_time(:millisecond) - start_time

      Logger.info(
        "[GroupAgent] Tool #{name} completed in #{duration_ms}ms attempts=#{attempts_used}"
      )

      status = if tool_result_error?(result), do: "error", else: "complete"
      completed_stage = tool_progress_stage(name, status)

      broadcast_agent_progress(chat_id, progress_label, name, status, %{
        "durationMs" => duration_ms,
        "attempts" => attempts_used,
        "stage" => completed_stage
      })

      add_tool_runtime_metadata(result, name, duration_ms)
    else
      Logger.warning("[GroupAgent] Blocked disabled tool call #{name}")
      broadcast_agent_progress(chat_id, "Finalizing...", name, "error")
      %{error: "Tool '#{name}' is disabled for this group."}
    end
  end

  defp execute_tool_with_recovery(name, input, user_id, chat_id, attempt) do
    result = execute_tool_once(name, input, user_id, chat_id)

    cond do
      tool_result_error?(result) and attempt < @max_tool_attempts and
          recoverable_tool_error?(name, result) ->
        next_attempt = attempt + 1
        error_message = tool_error_message(result)

        Logger.warning(
          "[GroupAgent] Tool #{name} failed on attempt #{attempt}, retrying (#{next_attempt}/#{@max_tool_attempts}) error=#{error_message}"
        )

        broadcast_agent_progress(
          chat_id,
          "Thinking...",
          name,
          "running",
          %{"attempt" => next_attempt, "stage" => "thinking"}
        )

        execute_tool_with_recovery(name, input, user_id, chat_id, next_attempt)

      true ->
        annotate_tool_result(result, name, attempt)
    end
  end

  defp execute_tool_once(name, input, user_id, chat_id) do
    case name do
      "search_google" -> Vibe.AI.Tools.Research.search(input)
      "read_url" -> Vibe.AI.Tools.Research.read(input)
      "analyze_image" -> Vibe.AI.Tools.Vision.analyze(input)
      "analyze_document" -> Vibe.AI.Tools.Document.analyze(input)
      "create_document" -> create_document_tool(chat_id, input, user_id)
      "find_rows" -> find_rows_tool(chat_id, input)
      "edit_rows" -> edit_rows_tool(chat_id, input, user_id)
      "delete_rows" -> delete_rows_tool(chat_id, input, user_id)
      "export_rows" -> export_rows_tool(chat_id, input, user_id)
      "delete_document" -> delete_document_tool(chat_id, input, user_id)
      "pin_message" -> pin_message_tool(chat_id, input, user_id)
      _ -> %{error: "Unknown tool: #{name}"}
    end
  end

  defp annotate_tool_result(result, name, attempt) when is_map(result) do
    normalized =
      result
      |> Map.put_new(:tool, name)
      |> Map.put_new(:attempts_used, attempt)

    if tool_result_error?(normalized) do
      Map.put_new(normalized, :recovery_hint, tool_recovery_hint(name, normalized))
    else
      normalized
    end
  end

  defp annotate_tool_result(result, name, attempt) do
    %{
      ok: false,
      tool: name,
      attempts_used: attempt,
      error: "Tool returned non-map result",
      raw_result: inspect(result)
    }
  end

  defp add_tool_runtime_metadata(result, name, duration_ms) when is_map(result) do
    result
    |> Map.put_new(:tool, name)
    |> Map.put_new(:duration_ms, duration_ms)
  end

  defp add_tool_runtime_metadata(result, name, duration_ms) do
    %{
      ok: false,
      tool: name,
      duration_ms: duration_ms,
      error: "Tool returned non-map result",
      raw_result: inspect(result)
    }
  end

  defp tool_attempt_count(result) when is_map(result) do
    attempts =
      Map.get(result, :attempts_used) ||
        Map.get(result, "attempts_used") ||
        1

    if is_integer(attempts) and attempts > 0, do: attempts, else: 1
  end

  defp tool_attempt_count(_), do: 1

  defp tool_result_error?(result) when is_map(result) do
    has_error =
      Map.get(result, :error) ||
        Map.get(result, "error")

    not is_nil(has_error) and to_string(has_error) != ""
  end

  defp tool_result_error?(_), do: false

  defp recoverable_tool_error?(name, result) do
    error_text = tool_error_message(result)

    transient? =
      String.contains?(error_text, "timeout") or
        String.contains?(error_text, "connection") or
        String.contains?(error_text, "temporar") or
        String.contains?(error_text, "rate limit") or
        String.contains?(error_text, "api error") or
        String.contains?(error_text, "429")

    renderer_retry? =
      name == "export_rows" and
        (String.contains?(error_text, "renderer") or String.contains?(error_text, "http_error"))

    transient? or renderer_retry?
  end

  defp tool_error_message(result) when is_map(result) do
    result
    |> Map.get(:error, Map.get(result, "error"))
    |> case do
      nil -> Map.get(result, :reason, Map.get(result, "reason"))
      value -> value
    end
    |> to_string()
    |> String.downcase()
  end

  defp tool_error_message(_), do: ""

  defp tool_recovery_hint(name, result) do
    error_text = tool_error_message(result)

    case name do
      "find_rows" ->
        "Retry find_rows with a narrower query or with the exact column name."

      "edit_rows" ->
        "Run find_rows first to confirm row_index, then retry edit_rows using exact column names from the sheet."

      "delete_rows" ->
        "Run find_rows first, confirm row indices are in range, then retry delete_rows."

      "create_document" ->
        "Retry create_document with explicit operation, columns, and rows aligned to the schema."

      "export_rows" ->
        "Retry export_rows with valid row filters and a supported format (pdf or png)."

      "pin_message" ->
        "Retry pin_message with an explicit message_id or use target=latest_agent_file/latest_message."

      _ ->
        "Diagnose the tool error, adjust inputs, and retry the correct tool."
    end <>
      if(error_text != "", do: " Last error: #{String.slice(error_text, 0, 220)}", else: "")
  end

  defp tool_progress_label(name, input) do
    case name do
      "search_google" ->
        "Thinking..."

      "analyze_image" ->
        "Thinking..."

      "analyze_document" ->
        "Thinking..."

      "create_document" ->
        operation =
          input
          |> tool_input_value("operation")
          |> String.downcase()

        case operation do
          "append_rows" -> "Updating file..."
          "replace_rows" -> "Updating file..."
          "edit_current" -> "Updating file..."
          "revert_last" -> "Updating file..."
          "create_new" -> "Updating file..."
          _ -> "Updating file..."
        end

      "find_rows" ->
        "Thinking..."

      "edit_rows" ->
        "Updating file..."

      "delete_rows" ->
        "Updating file..."

      "export_rows" ->
        "Updating file..."

      "delete_document" ->
        "Updating file..."

      "pin_message" ->
        "Pinning..."

      _ ->
        "Thinking..."
    end
  end

  defp tool_progress_stage(name, status) do
    normalized_status = status |> to_string() |> String.downcase()

    cond do
      normalized_status == "complete" ->
        "finalizing"

      normalized_status == "error" ->
        "finalizing"

      name in ["find_rows", "search_google", "analyze_document", "analyze_image"] ->
        "thinking"

      name in ["pin_message"] ->
        "pinning"

      name in ["create_document", "edit_rows", "delete_rows", "delete_document"] ->
        "updating_file"

      name == "export_rows" ->
        "updating_file"

      true ->
        "thinking"
    end
  end

  defp broadcast_agent_progress(chat_id, label, tool, status, extra \\ %{})

  defp broadcast_agent_progress(chat_id, label, tool, status, extra) when is_binary(chat_id) do
    normalized_chat_id = chat_id |> String.trim()

    if normalized_chat_id != "" do
      normalized_label = label |> to_string() |> String.trim()
      normalized_tool = tool |> to_string() |> String.trim()

      normalized_status =
        status
        |> to_string()
        |> String.trim()
        |> default_if_blank("running")

      payload =
        %{
          "userId" => @agent_user_id,
          "isAgent" => true,
          "status" => normalized_status
        }
        |> then(fn acc ->
          if normalized_label == "", do: acc, else: Map.put(acc, "label", normalized_label)
        end)
        |> then(fn acc ->
          if normalized_tool == "", do: acc, else: Map.put(acc, "tool", normalized_tool)
        end)
        |> Map.merge(if(is_map(extra), do: extra, else: %{}))

      VibeWeb.Endpoint.broadcast!("chat:#{normalized_chat_id}", "agent-progress", payload)
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[GroupAgent] Failed to broadcast agent-progress chat_id=#{inspect(chat_id)} error=#{inspect(error)}"
      )

      :ok
  end

  defp broadcast_agent_progress(_chat_id, _label, _tool, _status, _extra), do: :ok

  defp create_document_tool(chat_id, input, user_id) do
    title =
      input
      |> tool_input_value("title")
      |> default_if_blank("Document")

    body =
      input
      |> tool_input_value("body")
      |> default_if_blank("Draft content")

    format =
      input
      |> tool_input_value("format")
      |> normalize_document_format()

    sections =
      case input do
        %{"sections" => raw_sections} -> normalize_section_headings(raw_sections)
        %{sections: raw_sections} -> normalize_section_headings(raw_sections)
        _ -> []
      end

    structured_body =
      if sections == [] do
        body
      else
        headings =
          sections
          |> Enum.map_join("\n", fn heading -> "## #{heading}\n\n- Add details here." end)

        body <> "\n\n" <> headings
      end

    case format do
      "csv" ->
        build_spreadsheet_document(chat_id, input, title, body, sections, user_id, "csv")

      "xlsx" ->
        build_spreadsheet_document(chat_id, input, title, body, sections, user_id, "xlsx")

      _ ->
        content =
          case format do
            "plain_text" ->
              "#{title}\n\n#{structured_body}"

            "html" ->
              build_html_document(title, structured_body)

            "json" ->
              Jason.encode!(%{
                title: title,
                content: structured_body,
                sections: sections
              })

            _ ->
              "# #{title}\n\n#{structured_body}"
          end

        extension = file_extension_for_document_format(format)

        with {:ok, storage} <- write_agent_document_file(title, content, extension),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 title,
                 format,
                 storage.relative_url,
                 storage.file_url,
                 [],
                 0,
                 merge_document_metadata(
                   build_document_metadata(format, body),
                   storage.metadata
                 ),
                 "create",
                 user_id
               ) do
          document_tool_response(
            doc,
            format,
            content,
            "Document created and attached."
          )
        else
          {:error, reason} ->
            Logger.error(
              "[GroupAgent] Failed to create document format=#{format}: #{inspect(reason)}"
            )

            document_error_response(title, format, reason)
        end
    end
  end

  defp build_spreadsheet_document(chat_id, input, title, body, sections, user_id, output_format) do
    latest_document = GroupAgentDocument.get_current(chat_id)
    current_document = resolve_current_spreadsheet_document(chat_id, latest_document)

    operation = resolve_spreadsheet_operation(input, current_document)
    resolved_output_format = resolve_spreadsheet_output_format(output_format, current_document)

    case operation do
      :create_new ->
        create_new_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          resolved_output_format
        )

      :append_rows ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :append_rows,
          resolved_output_format
        )

      :replace_rows ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :replace_rows,
          resolved_output_format
        )

      :revert_last ->
        revert_spreadsheet_document(
          chat_id,
          title,
          body,
          user_id,
          current_document,
          resolved_output_format
        )

      :edit_current ->
        edit_current_spreadsheet_document(
          chat_id,
          input,
          title,
          body,
          sections,
          user_id,
          current_document,
          :edit_current,
          resolved_output_format
        )
    end
  end

  defp normalize_document_format(raw_format) do
    raw_format
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "plain_text" -> "plain_text"
      "text" -> "plain_text"
      "html" -> "html"
      "json" -> "json"
      "csv" -> "csv"
      "xlsx" -> "xlsx"
      "excel" -> "xlsx"
      "spreadsheet" -> "xlsx"
      "google_sheet" -> "xlsx"
      "google_sheets" -> "xlsx"
      _ -> "markdown"
    end
  end

  defp resolve_spreadsheet_output_format(requested_format, current_document) do
    requested =
      requested_format
      |> to_string()
      |> String.trim()
      |> String.downcase()

    cond do
      requested == "csv" ->
        "csv"

      requested in ["xlsx", "excel", "spreadsheet", "google_sheet", "google_sheets"] ->
        "xlsx"

      is_struct(current_document, GroupAgentDocument) ->
        case current_document.format |> to_string() |> String.trim() |> String.downcase() do
          "csv" -> "csv"
          _ -> "xlsx"
        end

      true ->
        "xlsx"
    end
  end

  defp resolve_spreadsheet_operation(input, current_document) do
    raw_operation =
      input
      |> tool_input_value("operation")
      |> String.downcase()

    case raw_operation do
      op when op in ["create_new", "new"] ->
        :create_new

      "append_rows" ->
        :append_rows

      "append" ->
        :append_rows

      "replace_rows" ->
        :replace_rows

      "edit_current" ->
        :edit_current

      "edit" ->
        :edit_current

      "update" ->
        :edit_current

      "revert_last" ->
        :revert_last

      "undo" ->
        :revert_last

      "rollback" ->
        :revert_last

      _ ->
        if current_document, do: :edit_current, else: :create_new
    end
  end

  defp create_new_spreadsheet_document(
         chat_id,
         input,
         title,
         body,
         sections,
         user_id,
         output_format
       ) do
    columns = spreadsheet_columns(input, sections, [])

    explicit_rows_raw = tool_input_raw(input, "rows")

    rows =
      if is_list(explicit_rows_raw) and explicit_rows_raw == [] do
        []
      else
        spreadsheet_rows(input, columns, body, [])
      end

    Logger.info(
      "[GroupAgent] create_new_spreadsheet cols=#{inspect(columns)} row_count=#{length(rows)}"
    )

    {columns, rows} = sanitize_spreadsheet_data(columns, rows)

    with {:ok, storage, csv_content} <-
           write_spreadsheet_document_file(title, columns, rows, output_format),
         {:ok, doc} <-
           persist_document_version(
             chat_id,
             title,
             output_format,
             storage.relative_url,
             storage.file_url,
             columns,
             length(rows),
             merge_document_metadata(
               build_spreadsheet_metadata("create_new", nil, body),
               storage.metadata
             ),
             "create",
             user_id
           ) do
      spreadsheet_tool_response(
        doc,
        columns,
        rows,
        csv_content,
        "Spreadsheet created and attached. Future edits in this group update this file unless user asks for a new one."
      )
    else
      {:error, reason} ->
        Logger.error("[GroupAgent] Failed to create spreadsheet: #{inspect(reason)}")
        spreadsheet_error_response(title, reason, output_format)
    end
  end

  defp edit_current_spreadsheet_document(
         chat_id,
         input,
         title,
         body,
         sections,
         user_id,
         current_document,
         operation,
         output_format
       ) do
    if is_nil(current_document) do
      create_new_spreadsheet_document(
        chat_id,
        input,
        title,
        body,
        sections,
        user_id,
        output_format
      )
    else
      with {:ok, existing_csv} <- read_agent_document_file(current_document) do
        {existing_columns, existing_rows} = parse_csv_content(existing_csv)
        columns = spreadsheet_columns(input, sections, existing_columns)
        existing_rows_aligned = align_rows_to_column_count(existing_rows, length(columns))

        explicit_rows =
          input
          |> tool_input_raw("rows")
          |> normalize_spreadsheet_rows(columns)

        inferred_rows =
          maybe_infer_rows_from_body(body, columns, operation, explicit_rows)

        incoming_rows = if explicit_rows == [], do: inferred_rows, else: explicit_rows

        final_rows =
          case operation do
            :append_rows ->
              existing_rows_aligned ++ incoming_rows

            :replace_rows ->
              if incoming_rows == [], do: existing_rows_aligned, else: incoming_rows

            :edit_current ->
              if incoming_rows == [], do: existing_rows_aligned, else: incoming_rows
          end
          |> ensure_non_empty_rows(columns, body)

        {columns, final_rows} = sanitize_spreadsheet_data(columns, final_rows)

        with {:ok, storage, csv_content} <-
               write_spreadsheet_document_file(title, columns, final_rows, output_format),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 title,
                 output_format,
                 storage.relative_url,
                 storage.file_url,
                 columns,
                 length(final_rows),
                 merge_document_metadata(
                   build_spreadsheet_metadata(
                     to_string(operation),
                     current_document.version,
                     body
                   ),
                   storage.metadata
                 ),
                 "edit",
                 user_id
               ) do
          spreadsheet_tool_response(
            doc,
            columns,
            final_rows,
            csv_content,
            "Spreadsheet updated from current group context (version #{current_document.version} -> #{doc.version})."
          )
        else
          {:error, reason} ->
            Logger.error("[GroupAgent] Failed to edit spreadsheet: #{inspect(reason)}")
            spreadsheet_error_response(title, reason, output_format)
        end
      else
        {:error, :enoent} ->
          Logger.warning(
            "[GroupAgent] Current spreadsheet source missing for chat #{chat_id}; rebuilding from current schema."
          )

          columns = spreadsheet_columns(input, sections, List.wrap(current_document.columns))

          incoming_rows =
            input
            |> tool_input_raw("rows")
            |> normalize_spreadsheet_rows(columns)

          final_rows = ensure_non_empty_rows(incoming_rows, columns, body)

          with {:ok, storage, csv_content} <-
                 write_spreadsheet_document_file(title, columns, final_rows, output_format),
               {:ok, doc} <-
                 persist_document_version(
                   chat_id,
                   title,
                   output_format,
                   storage.relative_url,
                   storage.file_url,
                   columns,
                   length(final_rows),
                   merge_document_metadata(
                     build_spreadsheet_metadata(
                       "rebuild_missing_source",
                       current_document.version,
                       body
                     ),
                     storage.metadata
                   ),
                   "edit",
                   user_id
                 ) do
            spreadsheet_tool_response(
              doc,
              columns,
              final_rows,
              csv_content,
              "Source file was missing; rebuilt and attached a fresh spreadsheet version."
            )
          else
            {:error, reason} ->
              Logger.error(
                "[GroupAgent] Failed to rebuild missing spreadsheet: #{inspect(reason)}"
              )

              spreadsheet_error_response(title, reason, output_format)
          end

        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to read current spreadsheet: #{inspect(reason)}")
          spreadsheet_error_response(title, reason, output_format)
      end
    end
  end

  defp revert_spreadsheet_document(
         chat_id,
         title,
         body,
         user_id,
         current_document,
         output_format
       ) do
    if is_nil(current_document) do
      %{
        ok: false,
        format: output_format,
        title: title,
        error: "No active spreadsheet to revert in this group."
      }
    else
      previous_document = find_previous_document(chat_id, current_document)

      if is_nil(previous_document) do
        %{
          ok: false,
          format: output_format,
          title: title,
          error: "No previous spreadsheet version available to revert."
        }
      else
        with {:ok, csv_content} <- read_agent_document_file(previous_document),
             {columns, rows} <- parse_csv_content(csv_content),
             {:ok, storage, normalized_csv_content} <-
               write_spreadsheet_document_file(
                 previous_document.title,
                 columns,
                 rows,
                 output_format
               ),
             {:ok, doc} <-
               persist_document_version(
                 chat_id,
                 previous_document.title,
                 output_format,
                 storage.relative_url,
                 storage.file_url,
                 columns,
                 length(rows),
                 merge_document_metadata(
                   build_spreadsheet_metadata("revert_last", current_document.version, body),
                   storage.metadata
                 ),
                 "revert",
                 user_id
               ) do
          spreadsheet_tool_response(
            doc,
            columns,
            rows,
            normalized_csv_content,
            "Reverted spreadsheet to previous content safely. A new version snapshot was created."
          )
        else
          {:error, reason} ->
            Logger.error("[GroupAgent] Failed to revert spreadsheet: #{inspect(reason)}")
            spreadsheet_error_response(title, reason, output_format)
        end
      end
    end
  end

  defp find_previous_document(chat_id, %GroupAgentDocument{} = current_document) do
    case current_document.previous_document_id do
      prev_id when is_binary(prev_id) ->
        case GroupAgentDocument.get_by_id(prev_id) do
          %GroupAgentDocument{chat_id: ^chat_id} = previous -> previous
          _ -> GroupAgentDocument.get_previous(chat_id, current_document.version)
        end

      _ ->
        GroupAgentDocument.get_previous(chat_id, current_document.version)
    end
  end

  defp persist_document_version(
         chat_id,
         title,
         format,
         relative_url,
         file_url,
         columns,
         row_count,
         metadata,
         change_type,
         user_id
       ) do
    GroupAgentDocument.create_new_version(chat_id, %{
      title: default_if_blank(title, "Spreadsheet"),
      format: default_if_blank(format, "csv"),
      relative_url: relative_url,
      file_url: file_url,
      columns: normalize_string_list(columns),
      row_count: max(row_count || 0, 0),
      metadata: if(is_map(metadata), do: metadata, else: %{}),
      change_type: change_type,
      created_by_user_id: user_id
    })
  end

  defp spreadsheet_tool_response(doc, columns, rows, csv_content, note) do
    format =
      doc.format
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> case do
        "csv" -> "csv"
        _ -> "xlsx"
      end

    %{
      ok: true,
      title: doc.title,
      format: format,
      columns: columns,
      rows: rows,
      row_count: length(rows),
      content: csv_content,
      download_path: doc.relative_url,
      file_url: doc.file_url,
      version: doc.version,
      change_type: doc.change_type,
      note: note
    }
  end

  defp spreadsheet_error_response(title, reason, output_format \\ "xlsx") do
    %{
      ok: false,
      error: "Failed to handle spreadsheet file",
      reason: inspect(reason),
      format: if(output_format == "csv", do: "csv", else: "xlsx"),
      title: title
    }
  end

  defp document_tool_response(doc, format, content, note) do
    %{
      ok: true,
      title: doc.title,
      format: format,
      content: content,
      download_path: doc.relative_url,
      file_url: doc.file_url,
      version: doc.version,
      note: note
    }
  end

  defp document_error_response(title, format, reason) do
    %{
      ok: false,
      title: title,
      format: format,
      error: "Failed to create document",
      reason: inspect(reason)
    }
  end


  defp find_rows_tool(chat_id, input) do
    query = tool_input_value(input, "query") |> String.downcase()
    column_filter = tool_input_value(input, "column")
    limit = tool_input_int(input, "limit", 20)

    with {:ok, document} <- get_current_document(chat_id),
         {:ok, csv} <- read_agent_document_file(document) do
      {columns, rows} = parse_csv_content(csv)

      col_index =
        if column_filter != "" do
          Enum.find_index(columns, fn c ->
            String.downcase(c) == String.downcase(column_filter)
          end)
        else
          nil
        end

      matches =
        rows
        |> Enum.with_index(1)
        |> Enum.filter(fn {row, _idx} ->
          if col_index do
            cell = Enum.at(row, col_index, "")
            String.contains?(String.downcase(cell), query)
          else
            Enum.any?(row, fn cell -> String.contains?(String.downcase(cell), query) end)
          end
        end)
        |> Enum.take(limit)
        |> Enum.map(fn {row, idx} ->
          values =
            columns
            |> Enum.zip(row)
            |> Map.new()

          %{index: idx, values: values}
        end)

      total =
        rows
        |> Enum.count(fn row ->
          if col_index do
            String.contains?(String.downcase(Enum.at(row, col_index, "")), query)
          else
            Enum.any?(row, fn cell -> String.contains?(String.downcase(cell), query) end)
          end
        end)

      %{ok: true, columns: columns, rows: matches, total_matches: total, showing: length(matches)}
    else
      {:error, :no_document} -> %{error: "No active spreadsheet for this group."}
      {:error, reason} -> %{error: "Failed to read spreadsheet: #{inspect(reason)}"}
    end
  end

  defp edit_rows_tool(chat_id, input, user_id) do
    raw_edits = tool_input_raw(input, "edits") || []

    edits =
      raw_edits
      |> List.wrap()
      |> Enum.map(fn edit ->
        idx = tool_input_int(edit, "row_index", 0)
        values = tool_input_raw(edit, "values") || %{}
        {idx, values}
      end)
      |> Enum.reject(fn {idx, _} -> idx < 1 end)

    if edits == [] do
      %{error: "No valid edits provided. Each edit needs row_index (>= 1) and values."}
    else
      with {:ok, document} <- get_current_document(chat_id),
           {:ok, csv} <- read_agent_document_file(document) do
        {columns, rows} = parse_csv_content(csv)
        max_idx = length(rows)

        col_lookup =
          columns
          |> Enum.with_index()
          |> Enum.map(fn {c, i} -> {String.downcase(c), i} end)
          |> Map.new()

        {updated_rows, change_log, skipped_indices} =
          Enum.reduce(edits, {rows, [], []}, fn {row_idx, values}, {acc_rows, changes, skipped} ->
            if row_idx > max_idx do
              {acc_rows, changes, [row_idx | skipped]}
            else
              current_row = Enum.at(acc_rows, row_idx - 1)

              {updated_row, before_values, after_values} =
                Enum.reduce(values, {current_row, %{}, %{}}, fn {col_name, new_val},
                                                                {row_acc, before_acc, after_acc} ->
                  case Map.get(col_lookup, String.downcase(to_string(col_name))) do
                    nil ->
                      {row_acc, before_acc, after_acc}

                    col_idx ->
                      old_value = Enum.at(row_acc, col_idx, "")
                      new_value = to_string(new_val)

                      if old_value == new_value do
                        {row_acc, before_acc, after_acc}
                      else
                        column_name = Enum.at(columns, col_idx) || to_string(col_name)

                        {
                          List.replace_at(row_acc, col_idx, new_value),
                          Map.put(before_acc, column_name, old_value),
                          Map.put(after_acc, column_name, new_value)
                        }
                      end
                  end
                end)

              if map_size(after_values) == 0 do
                {acc_rows, changes, skipped}
              else
                change_entry = %{row_index: row_idx, before: before_values, after: after_values}

                {List.replace_at(acc_rows, row_idx - 1, updated_row), [change_entry | changes],
                 skipped}
              end
            end
          end)

        changes = Enum.reverse(change_log)
        skipped_row_indices = skipped_indices |> Enum.reverse() |> Enum.uniq()

        title = document.title || "Spreadsheet"
        output_format = if document.format == "csv", do: "csv", else: "xlsx"

        if changes == [] do
          %{
            ok: true,
            updated_count: 0,
            row_count: length(rows),
            skipped_row_indices: skipped_row_indices,
            note: "No cell values changed. Verify row index and column names."
          }
        else
          with {:ok, storage, csv_content} <-
                 write_spreadsheet_document_file(title, columns, updated_rows, output_format),
               {:ok, doc} <-
                 persist_document_version(
                   chat_id,
                   title,
                   output_format,
                   storage.relative_url,
                   storage.file_url,
                   columns,
                   length(updated_rows),
                   merge_document_metadata(
                     build_spreadsheet_metadata("edit_rows", document.version, ""),
                     storage.metadata
                   ),
                   "edit",
                   user_id
                 ) do
            %{
              ok: true,
              updated_count: length(changes),
              row_count: length(updated_rows),
              changes: changes,
              skipped_row_indices: skipped_row_indices,
              content: csv_content,
              file_url: doc.file_url,
              version: doc.version
            }
          else
            {:error, reason} -> %{error: "Failed to save edits: #{inspect(reason)}"}
          end
        end
      else
        {:error, :no_document} -> %{error: "No active spreadsheet for this group."}
        {:error, reason} -> %{error: "Failed to read spreadsheet: #{inspect(reason)}"}
      end
    end
  end

  defp delete_rows_tool(chat_id, input, user_id) do
    raw_indices = tool_input_raw(input, "row_indices") || []

    indices =
      raw_indices
      |> List.wrap()
      |> Enum.map(fn i -> if is_integer(i), do: i, else: String.to_integer(to_string(i)) end)
      |> Enum.filter(&(&1 >= 1))
      |> Enum.uniq()
      |> Enum.sort(:desc)

    if indices == [] do
      %{error: "No valid row indices provided."}
    else
      with {:ok, document} <- get_current_document(chat_id),
           {:ok, csv} <- read_agent_document_file(document) do
        {columns, rows} = parse_csv_content(csv)
        max_idx = length(rows)

        valid_indices = Enum.filter(indices, &(&1 <= max_idx))

        if valid_indices == [] do
          %{error: "All indices out of range. Sheet has #{max_idx} rows."}
        else
          remaining_rows =
            Enum.reduce(valid_indices, rows, fn idx, acc ->
              List.delete_at(acc, idx - 1)
            end)

          title = document.title || "Spreadsheet"
          output_format = if document.format == "csv", do: "csv", else: "xlsx"

          with {:ok, storage, _csv_content} <-
                 write_spreadsheet_document_file(title, columns, remaining_rows, output_format),
               {:ok, doc} <-
                 persist_document_version(
                   chat_id,
                   title,
                   output_format,
                   storage.relative_url,
                   storage.file_url,
                   columns,
                   length(remaining_rows),
                   merge_document_metadata(
                     build_spreadsheet_metadata("delete_rows", document.version, ""),
                     storage.metadata
                   ),
                   "edit",
                   user_id
                 ) do
            %{
              ok: true,
              deleted_count: length(valid_indices),
              remaining_rows: length(remaining_rows),
              file_url: doc.file_url,
              version: doc.version
            }
          else
            {:error, reason} -> %{error: "Failed to save after delete: #{inspect(reason)}"}
          end
        end
      else
        {:error, :no_document} -> %{error: "No active spreadsheet for this group."}
        {:error, reason} -> %{error: "Failed to read spreadsheet: #{inspect(reason)}"}
      end
    end
  end

  defp pin_message_tool(chat_id, input, user_id) do
    explicit_message_id =
      input
      |> tool_input_value("message_id")
      |> default_if_blank("")

    target =
      input
      |> tool_input_value("target")
      |> normalize_pin_target()

    pinned = tool_input_bool(input, "pinned", true)

    Logger.info(
      "[GroupAgent] pin_message_tool start chat_id=#{chat_id} user_id=#{user_id} target=#{target} explicit_message_id=#{if(explicit_message_id == "", do: "(none)", else: explicit_message_id)} pinned=#{pinned}"
    )

    with {:ok, message} <-
           resolve_pin_target_message(chat_id, user_id, explicit_message_id, target),
         {:ok, _} <- Vibe.Chat.set_message_pin(chat_id, message.id, user_id, pinned) do
      broadcast_pinned_updated(chat_id, message.id, pinned, %{
        "userId" => user_id,
        "target" => target
      })

      Logger.info(
        "[GroupAgent] pin_message_tool ok chat_id=#{chat_id} user_id=#{user_id} message_id=#{message.id} message_type=#{message.type} pinned=#{pinned}"
      )

      %{
        ok: true,
        pinned: pinned,
        action: if(pinned, do: "pinned", else: "unpinned"),
        target: target,
        message_id: message.id,
        message_type: message.type,
        file_url: message.media_url,
        note:
          if(pinned,
            do: "Pinned message #{message.id}.",
            else: "Unpinned message #{message.id}."
          )
      }
    else
      {:error, :no_target_message} ->
        Logger.warning(
          "[GroupAgent] pin_message_tool no_target_message chat_id=#{chat_id} user_id=#{user_id} target=#{target}"
        )

        %{error: "No message found to pin for target '#{target}'."}

      {:error, :not_found} ->
        Logger.warning(
          "[GroupAgent] pin_message_tool message_not_found chat_id=#{chat_id} user_id=#{user_id} explicit_message_id=#{if(explicit_message_id == "", do: "(none)", else: explicit_message_id)}"
        )

        %{error: "Message not found for pinning."}

      {:error, :invalid_id} ->
        Logger.warning(
          "[GroupAgent] pin_message_tool invalid_message_id chat_id=#{chat_id} user_id=#{user_id} explicit_message_id=#{if(explicit_message_id == "", do: "(none)", else: explicit_message_id)}"
        )

        %{error: "Invalid message_id format for pinning."}

      {:error, :forbidden} ->
        Logger.warning(
          "[GroupAgent] pin_message_tool forbidden chat_id=#{chat_id} user_id=#{user_id}"
        )

        %{error: "Not allowed to pin messages in this chat."}

      {:error, reason} ->
        Logger.warning(
          "[GroupAgent] pin_message_tool error chat_id=#{chat_id} user_id=#{user_id} reason=#{inspect(reason)}"
        )

        %{error: "Failed to update pin: #{inspect(reason)}"}
    end
  end

  defp resolve_pin_target_message(chat_id, user_id, explicit_message_id, target)
       when is_binary(explicit_message_id) do
    if explicit_message_id != "" do
      case Vibe.Chat.get_message(chat_id, explicit_message_id, user_id) do
        nil -> {:error, :not_found}
        message -> {:ok, normalize_pin_message(message)}
      end
    else
      find_pin_target_message(chat_id, user_id, target)
    end
  end

  defp resolve_pin_target_message(chat_id, user_id, _explicit_message_id, target) do
    find_pin_target_message(chat_id, user_id, target)
  end

  defp find_pin_target_message(chat_id, user_id, target) do
    candidate =
      Vibe.Chat.get_messages_for_user(chat_id, user_id)
      |> List.wrap()
      |> Enum.reverse()
      |> Enum.find(&pin_target_match?(&1, target))

    case candidate do
      nil -> {:error, :no_target_message}
      message -> {:ok, normalize_pin_message(message)}
    end
  end

  defp pin_target_match?(message, target) do
    type = pin_message_value(message, :type) |> to_string() |> String.downcase()
    from_id = pin_message_value(message, :from_id) |> to_string()

    case target do
      "latest_agent_file" ->
        type == "file" and from_id == @agent_user_id

      "latest_file" ->
        type == "file"

      _ ->
        true
    end
  end

  defp normalize_pin_message(message) do
    %{
      id: pin_message_value(message, :id) |> to_string(),
      type: pin_message_value(message, :type) |> to_string() |> default_if_blank("text"),
      media_url:
        message
        |> pin_message_value(:media_url)
        |> case do
          value when is_binary(value) -> String.trim(value)
          _ -> nil
        end
    }
  end

  defp pin_message_value(message, key) when is_map(message) and is_atom(key) do
    Map.get(message, key) || Map.get(message, Atom.to_string(key))
  end

  defp pin_message_value(_, _), do: nil

  defp normalize_pin_target(raw_target) do
    target =
      raw_target
      |> to_string()
      |> String.trim()
      |> String.downcase()

    case target do
      "" -> "latest_agent_file"
      "latest-agent-file" -> "latest_agent_file"
      "current_file" -> "latest_agent_file"
      "latest_document" -> "latest_agent_file"
      "latest-document" -> "latest_agent_file"
      "latest-file" -> "latest_file"
      "file" -> "latest_file"
      "latest-message" -> "latest_message"
      "message" -> "latest_message"
      "latest_agent_file" -> "latest_agent_file"
      "latest_file" -> "latest_file"
      "latest_message" -> "latest_message"
      _ -> "latest_agent_file"
    end
  end

  defp broadcast_pinned_updated(chat_id, message_id, pinned, extra \\ %{})

  defp broadcast_pinned_updated(chat_id, message_id, pinned, extra) do
    normalized_chat_id = chat_id |> to_string() |> String.trim()
    normalized_message_id = message_id |> to_string() |> String.trim()

    payload =
      %{
        "messageId" => normalized_message_id,
        "pinned" => pinned
      }
      |> Map.merge(if(is_map(extra), do: extra, else: %{}))

    if normalized_chat_id != "" and normalized_message_id != "" do
      Logger.info(
        "[GroupAgent] broadcast pinned-updated chat_id=#{normalized_chat_id} message_id=#{normalized_message_id} pinned=#{pinned} extra_keys=#{inspect(Map.keys(extra || %{}))}"
      )

      VibeWeb.Endpoint.broadcast!("chat:#{normalized_chat_id}", "pinned-updated", payload)
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[GroupAgent] Failed to broadcast pinned-updated chat_id=#{inspect(chat_id)} message_id=#{inspect(message_id)} error=#{inspect(error)}"
      )

      :ok
  end

  defp delete_document_tool(chat_id, input, _user_id) do
    confirm =
      case input do
        %{"confirm" => true} -> true
        %{confirm: true} -> true
        _ -> false
      end

    if !confirm do
      %{error: "Deletion not confirmed. Set confirm=true to delete."}
    else
      current = GroupAgentDocument.get_current(chat_id)

      if current do
        {deleted_count, _} = GroupAgentDocument.clear_by_chat(chat_id)

        Logger.info(
          "[GroupAgent] delete_document: cleared #{deleted_count} document versions for chat #{chat_id}"
        )

        %{
          status: "deleted",
          message: "Document '#{current.title}' and all its versions have been removed.",
          deleted_versions: deleted_count
        }
      else
        %{status: "no_document", message: "No document found in this group to delete."}
      end
    end
  end

  defp export_rows_tool(chat_id, input, user_id) do
    title = tool_input_value(input, "title") |> default_if_blank("Export")
    query = tool_input_value(input, "query")
    raw_indices = tool_input_raw(input, "row_indices")
    format = tool_input_value(input, "format") |> default_if_blank("pdf")

    with {:ok, document} <- get_current_document(chat_id),
         {:ok, csv} <- read_agent_document_file(document) do
      {columns, rows} = parse_csv_content(csv)

      selected_rows =
        cond do
          is_list(raw_indices) and raw_indices != [] ->
            indices =
              Enum.map(raw_indices, fn i ->
                if is_integer(i), do: i, else: String.to_integer(to_string(i))
              end)

            Enum.filter(rows |> Enum.with_index(1), fn {_row, idx} -> idx in indices end)
            |> Enum.map(fn {row, _idx} -> row end)

          query != "" ->
            q = String.downcase(query)

            Enum.filter(rows, fn row ->
              Enum.any?(row, fn cell -> String.contains?(String.downcase(cell), q) end)
            end)

          true ->
            rows
        end

      if selected_rows == [] do
        %{error: "No rows matched the filter."}
      else
        render_payload = %{
          "title" => title,
          "columns" => columns,
          "rows" => selected_rows,
          "format" => format,
          "meta" => "#{length(selected_rows)} rows from #{document.title || "spreadsheet"}"
        }

        case call_doc_renderer("/render", render_payload) do
          {:ok, binary_content, content_type} ->
            extension = if format == "png", do: "png", else: "pdf"

            with {:ok, storage} <-
                   write_agent_document_binary_file(title, binary_content, extension),
                 {:ok, doc} <-
                   persist_document_version(
                     chat_id,
                     title,
                     extension,
                     storage.relative_url,
                     storage.file_url,
                     [],
                     length(selected_rows),
                     merge_document_metadata(
                       %{
                         "operation" => "export_rows",
                         "source_format" => document.format,
                         "export_format" => format
                       },
                       storage.metadata
                     ),
                     "create",
                     user_id
                   ) do
              %{
                ok: true,
                title: title,
                format: format,
                row_count: length(selected_rows),
                file_url: doc.file_url,
                note: "Exported #{length(selected_rows)} rows as #{String.upcase(format)}."
              }
            else
              {:error, reason} -> %{error: "Failed to save export: #{inspect(reason)}"}
            end

          {:error, reason} ->
            Logger.error("[GroupAgent] Doc renderer failed: #{inspect(reason)}")
            %{error: "Export rendering failed. The document renderer may not be available."}
        end
      end
    else
      {:error, :no_document} -> %{error: "No active spreadsheet for this group."}
      {:error, reason} -> %{error: "Failed to read spreadsheet: #{inspect(reason)}"}
    end
  end

  defp get_current_document(chat_id) do
    case GroupAgentDocument.get_current(chat_id) do
      nil -> {:error, :no_document}
      doc -> {:ok, doc}
    end
  end

  defp call_doc_renderer(path, payload) do
    url = doc_renderer_url() <> path
    body = Jason.encode!(payload)
    headers = [{"content-type", "application/json"}]

    case :httpc.request(
           :post,
           {String.to_charlist(url),
            Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
            ~c"application/json", body},
           [{:timeout, 30_000}, {:connect_timeout, 5_000}],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} when status in 200..299 ->
        content_type =
          resp_headers
          |> Enum.find_value("application/octet-stream", fn
            {~c"content-type", ct} -> List.to_string(ct)
            _ -> nil
          end)

        {:ok, resp_body, content_type}

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, {:renderer_http_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:renderer_connection_error, reason}}
    end
  end

  defp doc_renderer_url do
    System.get_env("DOC_RENDERER_URL") || "http://127.0.0.1:5050"
  end

  defp tool_input_int(input, key, default) do
    case tool_input_raw(input, key) do
      nil ->
        default

      val when is_integer(val) ->
        val

      val ->
        case Integer.parse(to_string(val)) do
          {int, _} -> int
          :error -> default
        end
    end
  end

  defp tool_input_bool(input, key, default \\ false) do
    case tool_input_raw(input, key) do
      nil ->
        default

      value when value in [true, "true", "TRUE", "1", 1, "yes", "YES", "on", "ON"] ->
        true

      value when value in [false, "false", "FALSE", "0", 0, "no", "NO", "off", "OFF"] ->
        false

      value when is_binary(value) ->
        normalized = value |> String.trim() |> String.downcase()
        normalized in ["true", "1", "yes", "on"]

      _ ->
        default
    end
  end

  defp file_extension_for_document_format(format) do
    case format do
      "plain_text" -> "txt"
      "html" -> "html"
      "json" -> "json"
      _ -> "md"
    end
  end

  defp build_spreadsheet_metadata(operation, source_version, body) do
    %{
      "operation" => operation,
      "source_version" => source_version,
      "request_hint" => body |> to_string() |> String.slice(0, 300)
    }
  end

  defp build_document_metadata(format, body) do
    %{
      "operation" => "create_document",
      "format" => format,
      "request_hint" => body |> to_string() |> String.slice(0, 300)
    }
  end

  defp spreadsheet_columns(input, sections, fallback_columns \\ []) do
    columns =
      input
      |> tool_input_raw("columns")
      |> normalize_string_list()

    cond do
      columns != [] ->
        columns

      sections != [] ->
        sections

      fallback_columns != [] ->
        fallback_columns

      true ->
        ["Item", "Value"]
    end
  end

  defp spreadsheet_rows(input, columns, body, fallback_rows \\ []) do
    normalized_rows =
      input
      |> tool_input_raw("rows")
      |> normalize_spreadsheet_rows(columns)

    cond do
      normalized_rows != [] ->
        normalized_rows

      fallback_rows != [] ->
        align_rows_to_column_count(fallback_rows, length(columns))

      true ->
        [default_spreadsheet_row(columns, body)]
    end
  end

  defp normalize_spreadsheet_rows(raw_rows, columns) when is_list(raw_rows) do
    raw_rows
    |> Enum.map(&normalize_single_spreadsheet_row(&1, columns))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_spreadsheet_rows(_, _), do: []

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_list(raw_row) do
    raw_row
    |> Enum.map(&normalize_spreadsheet_cell/1)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_map(raw_row) do
    normalized_lookup =
      raw_row
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), normalize_spreadsheet_cell(v)} end)
      |> Map.new()

    columns
    |> Enum.map(fn col -> Map.get(normalized_lookup, String.downcase(col), "") end)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(raw_row, columns) when is_binary(raw_row) do
    raw_row
    |> String.split(~r/\s*,\s*/, trim: true)
    |> Enum.map(&normalize_spreadsheet_cell/1)
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_single_spreadsheet_row(_, _), do: nil

  defp fit_row_to_column_count(values, column_count) when is_list(values) and column_count >= 0 do
    trimmed =
      values
      |> Enum.map(&normalize_spreadsheet_cell/1)
      |> Enum.take(column_count)

    padding_count = max(column_count - length(trimmed), 0)
    trimmed ++ List.duplicate("", padding_count)
  end

  defp align_rows_to_column_count(rows, column_count) when is_list(rows) do
    Enum.map(rows, &fit_row_to_column_count(&1, column_count))
  end

  defp align_rows_to_column_count(_, _), do: []

  defp ensure_non_empty_rows(rows, columns, body) do
    if rows == [] do
      [default_spreadsheet_row(columns, body)]
    else
      rows
    end
  end

  defp default_spreadsheet_row(columns, body) do
    first_cell =
      body
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> default_if_blank("Sample row")
      |> String.slice(0, 120)

    [first_cell]
    |> fit_row_to_column_count(length(columns))
  end

  defp normalize_spreadsheet_cell(value) do
    value
    |> to_string()
    |> String.replace(~r/\r\n?|\n/, " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
  end

  defp maybe_infer_rows_from_body(body, columns, operation, existing_rows) do
    if existing_rows == [] and operation == :append_rows and body_has_data_hint?(body) do
      [default_spreadsheet_row(columns, body)]
    else
      []
    end
  end

  defp body_has_data_hint?(body) do
    text = body |> to_string() |> String.trim() |> String.downcase()
    text != "" and text != "draft content" and text != "document"
  end

  defp merge_document_metadata(base_metadata, storage_metadata) do
    base = if is_map(base_metadata), do: base_metadata, else: %{}
    storage = if is_map(storage_metadata), do: storage_metadata, else: %{}
    Map.merge(base, storage)
  end

  defp sanitize_spreadsheet_data(columns, rows) when is_list(columns) and is_list(rows) do
    {columns, rows}
    |> strip_unwanted_columns()
    |> recalculate_totals()
  end

  defp strip_unwanted_columns({columns, rows}) do
    banned_patterns = ["جمع به حروف", "مبلغ به حروف", "amount in words", "به حروف"]

    indices_to_remove =
      columns
      |> Enum.with_index()
      |> Enum.filter(fn {col, _idx} ->
        col_down = col |> to_string() |> String.downcase()
        Enum.any?(banned_patterns, &String.contains?(col_down, &1))
      end)
      |> Enum.map(fn {_col, idx} -> idx end)
      |> MapSet.new()

    if MapSet.size(indices_to_remove) == 0 do
      {columns, rows}
    else
      Logger.info(
        "[GroupAgent] Sanitizer: stripping #{MapSet.size(indices_to_remove)} unwanted columns"
      )

      new_columns =
        columns
        |> Enum.with_index()
        |> Enum.reject(fn {_col, idx} -> MapSet.member?(indices_to_remove, idx) end)
        |> Enum.map(fn {col, _idx} -> col end)

      new_rows =
        Enum.map(rows, fn row ->
          row
          |> Enum.with_index()
          |> Enum.reject(fn {_val, idx} -> MapSet.member?(indices_to_remove, idx) end)
          |> Enum.map(fn {val, _idx} -> val end)
        end)

      {new_columns, new_rows}
    end
  end

  defp recalculate_totals({columns, rows}) do
    col_lower = Enum.map(columns, &(to_string(&1) |> String.downcase()))

    weight_idx = find_column_index(col_lower, ["وزن", "weight", "مقدار", "تعداد", "کیلو"])
    price_idx = find_column_index(col_lower, ["قیمت واحد", "فی", "price", "unit price", "قیمت"])
    total_idx = find_column_index(col_lower, ["جمع", "total", "مبلغ کل", "مبلغ", "جمع کل"])

    total_row_keywords = ["مجموع", "جمع کل", "مجموع کل", "total", "sum"]

    if weight_idx && price_idx && total_idx do
      Logger.info(
        "[GroupAgent] Sanitizer: found weight(#{weight_idx}), price(#{price_idx}), total(#{total_idx}) columns — recalculating"
      )

      recalculated_rows =
        Enum.map(rows, fn row ->
          is_summary =
            Enum.any?(row, fn cell ->
              cell_str = cell |> to_string() |> String.trim() |> String.downcase()

              Enum.any?(
                total_row_keywords,
                &(cell_str == &1 or String.starts_with?(cell_str, &1))
              )
            end)

          if is_summary do
            row
          else
            weight_val = parse_numeric(Enum.at(row, weight_idx))
            price_val = parse_numeric(Enum.at(row, price_idx))

            if weight_val > 0 and price_val > 0 do
              computed_total = round(weight_val * price_val)
              List.replace_at(row, total_idx, format_number(computed_total))
            else
              row
            end
          end
        end)

      final_rows =
        recalculate_summary_row(recalculated_rows, weight_idx, total_idx, total_row_keywords)

      {columns, final_rows}
    else
      {columns, rows}
    end
  end

  defp find_column_index(col_lower_list, keywords) do
    Enum.find_index(col_lower_list, fn col ->
      Enum.any?(keywords, &String.contains?(col, &1))
    end)
  end

  defp recalculate_summary_row(rows, weight_idx, total_idx, total_row_keywords) do
    Enum.map(rows, fn row ->
      is_summary =
        Enum.any?(row, fn cell ->
          cell_str = cell |> to_string() |> String.trim() |> String.downcase()
          Enum.any?(total_row_keywords, &(cell_str == &1 or String.starts_with?(cell_str, &1)))
        end)

      if is_summary do
        {weight_sum, total_sum} =
          Enum.reduce(rows, {0.0, 0.0}, fn r, {w_acc, t_acc} ->
            r_is_summary =
              Enum.any?(r, fn cell ->
                cell_str = cell |> to_string() |> String.trim() |> String.downcase()

                Enum.any?(
                  total_row_keywords,
                  &(cell_str == &1 or String.starts_with?(cell_str, &1))
                )
              end)

            if r_is_summary do
              {w_acc, t_acc}
            else
              w = parse_numeric(Enum.at(r, weight_idx))
              t = parse_numeric(Enum.at(r, total_idx))
              {w_acc + w, t_acc + t}
            end
          end)

        row
        |> List.replace_at(weight_idx, format_number(round(weight_sum)))
        |> List.replace_at(total_idx, format_number(round(total_sum)))
      else
        row
      end
    end)
  end

  defp parse_numeric(nil), do: 0.0
  defp parse_numeric(val) when is_number(val), do: val / 1

  defp parse_numeric(val) do
    cleaned =
      val
      |> to_string()
      |> String.trim()
      |> String.replace(~r/[۰٠]/, "0")
      |> String.replace(~r/[۱١]/, "1")
      |> String.replace(~r/[۲٢]/, "2")
      |> String.replace(~r/[۳٣]/, "3")
      |> String.replace(~r/[۴٤]/, "4")
      |> String.replace(~r/[۵٥]/, "5")
      |> String.replace(~r/[۶٦]/, "6")
      |> String.replace(~r/[۷٧]/, "7")
      |> String.replace(~r/[۸٨]/, "8")
      |> String.replace(~r/[۹٩]/, "9")
      |> String.replace(",", "")
      |> String.replace("/", "")
      |> String.replace(~r/[^\d.\-]/, "")

    case Float.parse(cleaned) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp format_number(num) when is_float(num), do: format_number(round(num))

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(val), do: to_string(val)

  defp write_spreadsheet_document_file(title, columns, rows, output_format) do
    csv_content = csv_from_rows(columns, rows)
    resolved_format = if output_format == "csv", do: "csv", else: "xlsx"

    case resolved_format do
      "csv" ->
        with {:ok, storage} <- write_agent_document_file(title, csv_content, "csv") do
          {:ok, storage, csv_content}
        end

      _ ->
        xlsx_result = generate_xlsx_binary(title, columns, rows)

        with {:ok, xlsx_binary} <- xlsx_result,
             {:ok, storage} <-
               write_agent_document_binary_file(
                 title,
                 xlsx_binary,
                 "xlsx",
                 %{
                   "spreadsheet_source_csv" => csv_content,
                   "spreadsheet_source_format" => "csv"
                 }
               ) do
          {:ok, storage, csv_content}
        end
    end
  end

  defp generate_xlsx_binary(title, columns, rows) do
    payload = %{"title" => title, "columns" => columns, "rows" => rows, "rtl" => true}

    case call_doc_renderer("/xlsx", payload) do
      {:ok, binary, _content_type} ->
        Logger.info("[GroupAgent] XLSX generated via Python renderer")
        {:ok, binary}

      {:error, reason} ->
        Logger.warning(
          "[GroupAgent] Python renderer unavailable (#{inspect(reason)}), falling back to built-in XLSX"
        )

        xlsx_from_rows(columns, rows)
    end
  end

  defp read_agent_document_file(%GroupAgentDocument{} = document) do
    metadata = if is_map(document.metadata), do: document.metadata, else: %{}

    case metadata["spreadsheet_source_csv"] || metadata[:spreadsheet_source_csv] do
      csv_source when is_binary(csv_source) and csv_source != "" ->
        {:ok, csv_source}

      _ ->
        case metadata["inline_content"] || metadata[:inline_content] do
          inline_content when is_binary(inline_content) ->
            {:ok, inline_content}

          _ ->
            read_agent_document_file(document.relative_url)
        end
    end
  end

  defp read_agent_document_file(relative_url) do
    with {:ok, full_path} <- resolve_agent_document_path(relative_url),
         {:ok, content} <- File.read(full_path) do
      {:ok, content}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp resolve_agent_document_path(relative_url) do
    normalized = relative_url |> to_string() |> String.trim()

    relative_path =
      cond do
        String.starts_with?(normalized, "/uploads/#{@agent_docs_dir}/") ->
          String.trim_leading(normalized, "/uploads/")

        String.starts_with?(normalized, "#{@agent_docs_dir}/") ->
          normalized

        true ->
          nil
      end

    if is_nil(relative_path) or relative_path == "" or String.contains?(relative_path, "..") do
      {:error, :invalid_document_path}
    else
      full_path = Path.expand(Path.join(@uploads_dir, relative_path))
      uploads_root = Path.expand(@uploads_dir)

      if String.starts_with?(full_path, uploads_root <> "/") do
        {:ok, full_path}
      else
        {:error, :invalid_document_path}
      end
    end
  end

  defp parse_csv_content(content) do
    rows =
      content
      |> to_string()
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&parse_csv_line/1)
      |> Enum.reject(&(&1 == []))

    case rows do
      [] ->
        {["Item", "Value"], []}

      [header | body_rows] ->
        columns =
          header
          |> sanitize_csv_columns()

        {columns, align_rows_to_column_count(body_rows, length(columns))}
    end
  end

  defp sanitize_csv_columns(columns) when is_list(columns) do
    columns
    |> sanitize_spreadsheet_columns()
    |> case do
      [] -> ["Item", "Value"]
      value -> value
    end
  end

  defp sanitize_spreadsheet_columns(columns) when is_list(columns) do
    normalized =
      columns
      |> Enum.with_index(1)
      |> Enum.map(fn {column, idx} ->
        column
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> default_if_blank("Column #{idx}")
      end)

    {deduped, _seen} =
      Enum.map_reduce(normalized, %{}, fn column, seen ->
        key = String.downcase(column)
        count = Map.get(seen, key, 0) + 1
        next_seen = Map.put(seen, key, count)
        final_name = if count == 1, do: column, else: "#{column} (#{count})"
        {final_name, next_seen}
      end)

    deduped
  end

  defp sanitize_spreadsheet_columns(_), do: []

  defp parse_csv_line(line) when is_binary(line) do
    line
    |> do_parse_csv_line([], "", false)
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp parse_csv_line(_), do: []

  defp do_parse_csv_line(<<>>, cells, cell, _in_quotes), do: [cell | cells]

  defp do_parse_csv_line(<<?", ?", rest::binary>>, cells, cell, true) do
    do_parse_csv_line(rest, cells, cell <> "\"", true)
  end

  defp do_parse_csv_line(<<?", rest::binary>>, cells, cell, true) do
    do_parse_csv_line(rest, cells, cell, false)
  end

  defp do_parse_csv_line(<<?", rest::binary>>, cells, cell, false) do
    do_parse_csv_line(rest, cells, cell, true)
  end

  defp do_parse_csv_line(<<?,, rest::binary>>, cells, cell, false) do
    do_parse_csv_line(rest, [cell | cells], "", false)
  end

  defp do_parse_csv_line(<<?\r, rest::binary>>, cells, cell, in_quotes) do
    do_parse_csv_line(rest, cells, cell, in_quotes)
  end

  defp do_parse_csv_line(<<char::utf8, rest::binary>>, cells, cell, in_quotes) do
    do_parse_csv_line(rest, cells, cell <> <<char::utf8>>, in_quotes)
  end

  defp csv_from_rows(columns, rows) do
    lines = [
      Enum.map_join(columns, ",", &csv_escape_cell/1)
      | Enum.map(rows, fn row -> Enum.map_join(row, ",", &csv_escape_cell/1) end)
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  defp csv_escape_cell(value) do
    text =
      value
      |> to_string()
      |> String.replace(~r/\r\n?|\n/, " ")

    escaped = String.replace(text, "\"", "\"\"")

    if String.contains?(escaped, ",") or String.contains?(escaped, "\"") or
         String.contains?(escaped, "\n") or String.contains?(escaped, "\r") do
      "\"#{escaped}\""
    else
      escaped
    end
  end

  defp write_agent_document_file(title, content, extension) do
    if byte_size(to_string(content || "")) > @max_agent_document_bytes do
      {:error, :document_too_large}
    else
      filename = build_agent_document_filename(title, extension)
      blob_key = build_agent_document_blob_key()
      relative_url = "/api/agent/document/#{blob_key}/#{filename}"

      {:ok,
       %{
         relative_url: relative_url,
         file_url: public_upload_url(relative_url),
         metadata: %{
           "storage_kind" => "db_inline",
           "blob_key" => blob_key,
           "download_name" => filename,
           "content_type" => content_type_for_extension(extension),
           "inline_content" => to_string(content || "")
         }
       }}
    end
  end

  defp write_agent_document_binary_file(title, binary_content, extension, extra_metadata \\ %{}) do
    if !is_binary(binary_content) do
      {:error, :invalid_document_binary}
    else
      if byte_size(binary_content) > @max_agent_document_bytes do
        {:error, :document_too_large}
      else
        filename = build_agent_document_filename(title, extension)
        blob_key = build_agent_document_blob_key()
        relative_url = "/api/agent/document/#{blob_key}/#{filename}"

        metadata =
          %{
            "storage_kind" => "db_inline",
            "blob_key" => blob_key,
            "download_name" => filename,
            "content_type" => content_type_for_extension(extension),
            "inline_content_base64" => Base.encode64(binary_content)
          }
          |> Map.merge(if(is_map(extra_metadata), do: extra_metadata, else: %{}))

        {:ok,
         %{
           relative_url: relative_url,
           file_url: public_upload_url(relative_url),
           metadata: metadata
         }}
      end
    end
  end

  defp xlsx_from_rows(columns, rows) do
    sanitized_columns =
      columns
      |> sanitize_spreadsheet_columns()
      |> case do
        [] -> ["Item", "Value"]
        value -> value
      end

    sanitized_rows =
      rows
      |> align_rows_to_column_count(length(sanitized_columns))
      |> Enum.map(&Enum.map(&1, fn value -> normalize_spreadsheet_cell(value) end))

    sheet_rows = [sanitized_columns | sanitized_rows]

    entries = [
      {~c"[Content_Types].xml", xlsx_content_types_xml()},
      {~c"_rels/.rels", xlsx_root_rels_xml()},
      {~c"xl/workbook.xml", xlsx_workbook_xml()},
      {~c"xl/_rels/workbook.xml.rels", xlsx_workbook_rels_xml()},
      {~c"xl/styles.xml", xlsx_styles_xml()},
      {~c"xl/worksheets/sheet1.xml", xlsx_sheet_xml(sheet_rows)}
    ]

    case :zip.create(~c"spreadsheet.xlsx", entries, [:memory]) do
      {:ok, {_name, zip_binary}} when is_binary(zip_binary) ->
        {:ok, zip_binary}

      {:ok, zip_binary} when is_binary(zip_binary) ->
        {:ok, zip_binary}

      {:error, reason} ->
        {:error, {:xlsx_zip_create_failed, reason}}

      other ->
        {:error, {:xlsx_zip_unexpected_result, other}}
    end
  end

  defp xlsx_content_types_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """
    |> String.trim()
  end

  defp xlsx_root_rels_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """
    |> String.trim()
  end

  defp xlsx_workbook_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """
    |> String.trim()
  end

  defp xlsx_workbook_rels_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
    |> String.trim()
  end

  defp xlsx_styles_xml do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2">
        <font>
          <sz val="11"/>
          <name val="Calibri"/>
        </font>
        <font>
          <b/>
          <sz val="11"/>
          <color rgb="FFFFFFFF"/>
          <name val="Calibri"/>
        </font>
      </fonts>
      <fills count="3">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FF2B5797"/><bgColor indexed="64"/></patternFill></fill>
      </fills>
      <borders count="2">
        <border>
          <left/><right/><top/><bottom/><diagonal/>
        </border>
        <border>
          <left style="thin"><color auto="1"/></left>
          <right style="thin"><color auto="1"/></right>
          <top style="thin"><color auto="1"/></top>
          <bottom style="thin"><color auto="1"/></bottom>
          <diagonal/>
        </border>
      </borders>
      <cellStyleXfs count="1">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
      </cellStyleXfs>
      <cellXfs count="3">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
          <alignment horizontal="center" vertical="center" wrapText="1"/>
        </xf>
        <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">
          <alignment vertical="center" wrapText="1"/>
        </xf>
      </cellXfs>
      <cellStyles count="1">
        <cellStyle name="Normal" xfId="0" builtinId="0"/>
      </cellStyles>
    </styleSheet>
    """
    |> String.trim()
  end

  defp xlsx_sheet_xml(rows) when is_list(rows) do
    col_count =
      case rows do
        [first | _] -> length(first)
        _ -> 1
      end

    cols_xml =
      1..col_count
      |> Enum.map_join("", fn i -> ~s(<col min="#{i}" max="#{i}" width="22" customWidth="1"/>) end)

    row_xml =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {cells, row_index} ->
        style_id = if row_index == 1, do: "1", else: "2"

        cell_xml =
          cells
          |> Enum.with_index(1)
          |> Enum.map_join("", fn {value, col_index} ->
            xlsx_cell_xml(row_index, col_index, value, style_id)
          end)

        ~s(<row r="#{row_index}">#{cell_xml}</row>)
      end)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetViews>
        <sheetView rightToLeft="true" workbookViewId="0"/>
      </sheetViews>
      <cols>#{cols_xml}</cols>
      <sheetData>#{row_xml}</sheetData>
    </worksheet>
    """
    |> String.trim()
  end

  defp xlsx_cell_xml(row_index, col_index, value, style_id \\ "0") do
    ref = excel_cell_ref(row_index, col_index)
    text = normalize_spreadsheet_cell(value)

    if text == "" do
      ~s(<c r="#{ref}" s="#{style_id}"/>)
    else
      preserve = if text != String.trim(text), do: ~s( xml:space="preserve"), else: ""
      escaped = xml_escape(text)
      ~s(<c r="#{ref}" s="#{style_id}" t="inlineStr"><is><t#{preserve}>#{escaped}</t></is></c>)
    end
  end

  defp excel_cell_ref(row_index, col_index) when row_index > 0 and col_index > 0 do
    excel_column_name(col_index) <> Integer.to_string(row_index)
  end

  defp excel_column_name(index) when index > 0 do
    do_excel_column_name(index, "")
  end

  defp do_excel_column_name(index, acc) when index > 0 do
    rem_value = rem(index - 1, 26)
    next_index = div(index - 1, 26)
    letter = <<rem_value + ?A>>
    do_excel_column_name(next_index, letter <> acc)
  end

  defp do_excel_column_name(0, acc), do: acc

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp build_agent_document_blob_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp content_type_for_extension(extension) do
    case extension |> to_string() |> String.trim() |> String.downcase() do
      "csv" -> "text/csv"
      "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      "xls" -> "application/vnd.ms-excel"
      "pdf" -> "application/pdf"
      "md" -> "text/markdown"
      "json" -> "application/json"
      "html" -> "text/html"
      "txt" -> "text/plain"
      _ -> "application/octet-stream"
    end
  end

  defp build_agent_document_filename(title, extension) do
    ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    slug = sanitize_filename_token(title)
    "#{ts}-#{slug}-#{suffix}.#{extension}"
  end

  defp sanitize_filename_token(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> default_if_blank("document")
    |> String.slice(0, 60)
  end

  defp public_upload_url(relative_url) do
    base_url =
      System.get_env("PUBLIC_BASE_URL") ||
        System.get_env("API_BASE_URL") ||
        endpoint_url()

    normalized_base = normalize_public_base_url(base_url)

    if is_binary(normalized_base) and normalized_base != "" do
      String.trim_trailing(normalized_base, "/") <> relative_url
    else
      relative_url
    end
  end

  defp normalize_public_base_url(raw) when is_binary(raw) do
    cleaned =
      raw
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> String.trim_leading("'")
      |> String.trim_trailing("'")

    fixed_bracketed =
      case Regex.run(~r/^https?:\/\/\[(https?:\/\/[^\]]+)\](\/.*)?$/i, cleaned) do
        [_, inner, path] when is_binary(path) ->
          inner <> path

        [_, inner, nil] ->
          inner

        [_, inner] ->
          inner

        _ ->
          case Regex.run(~r/^\[(https?:\/\/[^\]]+)\](\/.*)?$/i, cleaned) do
            [_, inner, path] when is_binary(path) -> inner <> path
            [_, inner, nil] -> inner
            [_, inner] -> inner
            _ -> cleaned
          end
      end

    fixed_double_scheme =
      fixed_bracketed
      |> String.replace_prefix("https://https://", "https://")
      |> String.replace_prefix("http://http://", "http://")

    fixed_double_scheme
  end

  defp normalize_public_base_url(_), do: ""

  defp endpoint_url do
    try do
      VibeWeb.Endpoint.url()
    rescue
      _ -> ""
    end
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,|]/, trim: true)
    |> normalize_string_list()
  end

  defp normalize_string_list(_), do: []

  defp tool_input_raw(input, key) do
    case input do
      %{^key => value} ->
        value

      %{} ->
        try do
          Map.get(input, String.to_existing_atom(key))
        rescue
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp tool_input_value(input, key) do
    case input do
      %{^key => value} ->
        to_string(value || "")

      %{} ->
        atom_value =
          try do
            Map.get(input, String.to_existing_atom(key), "")
          rescue
            _ -> ""
          end

        to_string(atom_value || "")

      _ ->
        ""
    end
    |> String.trim()
  end

  defp normalize_section_headings(raw_sections) when is_list(raw_sections) do
    raw_sections
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_section_headings(_), do: []

  defp build_html_document(title, body) do
    escaped_title = escape_html(title)
    escaped_body = escape_html(body)

    body_html =
      escaped_body
      |> String.split(~r/\r?\n/, trim: false)
      |> Enum.map_join("\n", fn line ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" -> ""
          String.starts_with?(trimmed, "## ") -> "<h2>#{String.trim_leading(trimmed, "## ")}</h2>"
          String.starts_with?(trimmed, "- ") -> "<li>#{String.trim_leading(trimmed, "- ")}</li>"
          true -> "<p>#{line}</p>"
        end
      end)

    """
    <!DOCTYPE html>
    <html dir="rtl" lang="fa">
    <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>#{escaped_title}</title>
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Tahoma, Arial, sans-serif;
      font-size: 15px;
      line-height: 1.6;
      color: #1a1a1a;
      background: #ffffff;
      padding: 20px;
      direction: rtl;
      text-align: right;
    }
    h1 {
      font-size: 22px;
      font-weight: 700;
      color: #2B5797;
      margin-bottom: 16px;
      padding-bottom: 10px;
      border-bottom: 2px solid #2B5797;
    }
    h2 {
      font-size: 17px;
      font-weight: 600;
      color: #333;
      margin: 16px 0 8px;
    }
    p { margin: 6px 0; }
    li { margin: 4px 0 4px 20px; }
    table {
      width: 100%;
      border-collapse: collapse;
      margin: 16px 0;
      direction: rtl;
    }
    th {
      background: #2B5797;
      color: #fff;
      font-weight: 600;
      padding: 10px 12px;
      text-align: right;
      border: 1px solid #1e3f6f;
      white-space: nowrap;
    }
    td {
      padding: 8px 12px;
      border: 1px solid #d0d0d0;
      text-align: right;
      vertical-align: top;
    }
    tr:nth-child(even) td { background: #f5f7fa; }
    tr:hover td { background: #e8edf4; }
    .summary-row td {
      font-weight: 700;
      background: #eef2f8;
      border-top: 2px solid #2B5797;
    }
    </style>
    </head>
    <body>
    <h1>#{escaped_title}</h1>
    #{body_html}
    </body>
    </html>
    """
    |> String.trim()
  end

  defp escape_html(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp default_if_blank(text, fallback) do
    trimmed = text |> to_string() |> String.trim()
    if trimmed == "", do: fallback, else: trimmed
  end

  defp maybe_attach_spreadsheet_fallback(
         _chat_id,
         _user_message,
         response,
         _enabled_tools,
         _user_id,
         existing_attachment \\ nil
       ) do
    %{text: response, attachment: existing_attachment}
  end

  defp extract_tool_attachment("create_document", result),
    do: attachment_from_document_result(result)

  defp extract_tool_attachment("edit_rows", result), do: attachment_from_document_result(result)
  defp extract_tool_attachment("delete_rows", result), do: attachment_from_document_result(result)
  defp extract_tool_attachment("export_rows", result), do: attachment_from_document_result(result)
  defp extract_tool_attachment(_tool_name, _result), do: nil

  defp attachment_from_document_result(result) when is_map(result) do
    ok? =
      Map.get(result, :ok) ||
        Map.get(result, "ok")

    file_url =
      Map.get(result, :file_url) ||
        Map.get(result, "file_url") ||
        Map.get(result, :download_path) ||
        Map.get(result, "download_path")

    with true <- ok? == true,
         url when is_binary(url) <- normalize_attachment_url(file_url),
         true <- url != "" do
      file_name = derive_file_name_from_url(url) || "document"
      %{url: url, file_name: file_name}
    else
      _ -> nil
    end
  end

  defp attachment_from_document_result(_), do: nil

  defp normalize_attachment_url(value) when is_binary(value) do
    normalized = value |> String.trim()

    cond do
      normalized == "" ->
        nil

      String.starts_with?(normalized, "http://") or String.starts_with?(normalized, "https://") ->
        normalized

      String.starts_with?(normalized, "/") ->
        public_upload_url(normalized)

      true ->
        normalized
    end
  end

  defp normalize_attachment_url(_), do: nil

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map(fn %{"text" => text} -> text end)
    |> Enum.join("")
  end

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(_), do: ""

  defp normalize_tools_input(raw_tools) do
    cond do
      is_list(raw_tools) ->
        Enum.map(raw_tools, &to_string/1)

      is_binary(raw_tools) ->
        raw_tools
        |> String.split(",")
        |> Enum.map(&String.trim/1)

      true ->
        []
    end
  end

  defp build_prompt_generation_instruction(user_input, enabled_tools) do
    tool_list =
      enabled_tools
      |> Enum.map_join(", ", &"`#{&1}`")

    """
    Create a highly detailed, comprehensive, and robust system prompt for an advanced AI assistant operating in a group chat environment.
    The prompt must be thorough and leave no ambiguity about how the agent should behave, respond, and format its output.
    You MUST include exhaustive details for every enabled tool and a set of explicit rules for safely executing them.
    Enabled tools for this assistant: #{tool_list}.

    Admin's precise intent for this agent:
    #{user_input}

    Required prompt structure (use clear section headers):
    1) Core Identity & Objective (Expand deeply on the agent's persona and primary purpose)
    2) Response Format & Tone Contract (Required tone, structure of messages, and output formatting)
    3) Comprehensive Tool Usage Rules (Detail WHEN and exactly HOW to use each tool, failure handling, and retry strategies)
    4) Spreadsheet & Document Standards (CRITICAL: Exhaustive rules on using Excel (.xlsx) over csv, maintaining precise columns, exact formatting requirements for data, error prevention)
    5) Clarification Policy (Exactly when and how the agent should ask for missing context before taking action)
    6) Safety, Tone & Boundary Constraints (What the agent must NEVER do, how to handle inappropriate requests)
    7) Detailed Execution Examples:
       - Example 1: A complex request where the agent uses a tool and handles the response.
       - Example 2: A request requiring spreadsheet generation, demonstrating exact payload formatting and structure.

    Return ONLY the final system prompt text. Do NOT include markdown fences, preambles, or concluding explanations. Provide the plain text of the system prompt ready to be injected.
    """
  end

  defp normalize_generated_prompt(raw_prompt, fallback_input) do
    generated =
      raw_prompt
      |> to_string()
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")

    if String.length(generated) < 40 do
      fallback_generated_prompt(fallback_input)
    else
      generated
    end
  end

  defp fallback_generated_prompt(user_input) do
    """
    #{@default_system_prompt}

    Role & Objective:
    #{user_input}

    Response Contract:
    - Prioritize direct, useful answers in short mobile-friendly format.
    - Avoid generic wording; be specific, actionable, and context-aware.
    - If intent is ambiguous, ask focused clarifying questions.

    Tool Usage Rules:
    - Use enabled tools whenever they materially improve accuracy or output quality.
    - If a requested action requires a disabled tool, state that clearly and offer alternatives.

    Spreadsheet & Document Standards:
    - For spreadsheet requests, default to Excel (.xlsx) unless user explicitly asks for csv.
    - Use clear professional column names and stable column order.
    - Keep each row aligned to the column schema (no missing/extra cells).
    - Normalize noisy data (trim spaces, consistent wording, remove filler placeholders).
    - Prefer consistent date/amount formats across rows.

    Clarification Policy:
    - Ask a short follow-up when key schema fields are missing.
    - If reasonable assumptions are needed, state them briefly.
    """
    |> String.trim()
  end

  defp normalize_url_list(raw_urls) when is_list(raw_urls) do
    raw_urls
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_url_list(raw_urls) when is_binary(raw_urls) do
    normalize_url_list([raw_urls])
  end

  defp normalize_url_list(_), do: []

  defp build_attachment_context(image_urls, document_urls) do
    image_lines = Enum.map(image_urls, &"- image: #{&1}")
    document_lines = Enum.map(document_urls, &"- document: #{&1}")
    lines = image_lines ++ document_lines
    if lines == [], do: "", else: "Attached context:\n" <> Enum.join(lines, "\n")
  end

  defp append_attachment_context(current_message, attachment_context) do
    base = current_message |> to_string() |> String.trim()

    if attachment_context == "" do
      base
    else
      [base, attachment_context]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
    end
  end

  defp summarize_attachments_for_memory(metadata) do
    images = normalize_url_list(Map.get(metadata, "image_urls", []))
    documents = normalize_url_list(Map.get(metadata, "document_urls", []))
    %{images: images, documents: documents}
  end

  defp append_attachment_summary_for_storage(content, %{images: images, documents: documents}) do
    summary_lines =
      (Enum.map(images, &"[image] #{&1}") ++ Enum.map(documents, &"[document] #{&1}"))
      |> Enum.uniq()

    if summary_lines == [] do
      content
    else
      [content, Enum.join(summary_lines, "\n")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp broadcast_agent_message(
         chat_id,
         agent_config,
         text,
         user_id,
         metadata,
         explicit_attachment \\ nil
       ) do
    Logger.info(
      "[GroupAgent] Broadcasting agent message chat_id=#{chat_id} len=#{String.length(text || "")}"
    )

    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)
    reply_to_id = Map.get(metadata, "reply_to_id")
    attachment = normalize_explicit_attachment(explicit_attachment)
    plain_text = sanitize_agent_plain_text(text, attachment)
    message_type = if attachment, do: "file", else: "text"

    payload_base = %{
      "id" => message_id,
      "fromId" => @agent_user_id,
      "chatId" => chat_id,
      "encryptedContent" => "",
      "plainContent" => plain_text,
      "type" => message_type,
      "timestamp" => timestamp,
      "status" => "sent",
      "isAgentMessage" => true,
      "agentName" => agent_config.name,
      "replyToId" => reply_to_id
    }

    payload =
      case attachment do
        %{url: url, file_name: file_name} ->
          payload_base
          |> Map.put("mediaUrl", url)
          |> Map.put("fileName", file_name)

        _ ->
          payload_base
      end

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)

    mirrored_message = Vibe.Chat.mirrored_message_payload(payload)

    Task.start(fn ->
      case ensure_agent_user_record() do
        :ok ->
          message_attrs_base = %{
            id: message_id,
            chat_id: chat_id,
            from_id: @agent_user_id,
            encrypted_content: AgentMessageCrypto.encrypt_for_storage(plain_text),
            type: message_type,
            timestamp: timestamp,
            reply_to_id: reply_to_id
          }

          message_attrs =
            case attachment do
              %{url: url} -> Map.put(message_attrs_base, :media_url, url)
              _ -> message_attrs_base
            end

          case Vibe.Chat.add_message(message_attrs, acting_user_id: user_id) do
            {:ok, _msg} ->
              Logger.info(
                "[GroupAgent] Agent message persisted chat_id=#{chat_id} message_id=#{message_id}"
              )

              maybe_refresh_pinned_agent_file(chat_id, message_id, message_type)

              participants = Vibe.Chat.get_all_participant_settings(chat_id)

              Enum.each(participants, fn p ->
                if p.user_id != @agent_user_id do
                  if p.deleted, do: Vibe.Chat.restore_if_deleted(chat_id, p.user_id)

                  VibeWeb.Endpoint.broadcast!("user:#{p.user_id}", "new_message", %{
                    chat_id: chat_id,
                    from_id: @agent_user_id,
                    message_id: message_id,
                    timestamp: timestamp,
                    muted: p.muted || false,
                    message: mirrored_message
                  })

                  if not p.muted do
                    _ =
                      Notifications.send_message_push(p.user_id, %{
                        "chat_id" => chat_id,
                        "message_id" => message_id,
                        "from_id" => @agent_user_id,
                        "type" => message_type,
                        "body" => plain_text,
                        "media_url" => attachment && attachment.url
                      })
                  end
                end
              end)

            {:error, reason} ->
              Logger.error("[GroupAgent] Failed to persist agent message: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.error("[GroupAgent] Failed to ensure agent user row: #{inspect(reason)}")
      end
    end)
  end

  defp maybe_refresh_pinned_agent_file(_chat_id, _message_id, message_type)
       when message_type != "file",
       do: :ok

  defp maybe_refresh_pinned_agent_file(chat_id, message_id, "file") do
    case Vibe.Chat.refresh_pinned_agent_file(chat_id, message_id) do
      {:ok, updated_count} when updated_count > 0 ->
        Logger.info(
          "[GroupAgent] Refreshed pinned agent file chat_id=#{chat_id} message_id=#{message_id} updated_users=#{updated_count}"
        )

        broadcast_pinned_updated(chat_id, message_id, true, %{
          "updatedUsers" => updated_count
        })

        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[GroupAgent] Failed to refresh pinned agent file chat_id=#{chat_id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[GroupAgent] Exception while refreshing pinned agent file chat_id=#{chat_id}: #{inspect(error)}"
      )

      :ok
  end

  defp ensure_agent_user_record do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    agent_user_id = Ecto.UUID.dump!(@agent_user_id)

    Repo.insert_all(
      "users",
      [
        %{
          id: agent_user_id,
          username: @agent_username,
          password_hash: "agent",
          public_key: "agent",
          device_id: "agent",
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:id],
      on_conflict: [set: [updated_at: now]]
    )

    :ok
  rescue
    error -> {:error, error}
  end

  defp normalize_explicit_attachment(%{url: url, file_name: file_name}) do
    with normalized_url when is_binary(normalized_url) <- normalize_attachment_url(url),
         true <- normalized_url != "" do
      resolved_name =
        file_name
        |> to_string()
        |> String.trim()
        |> case do
          "" -> derive_file_name_from_url(normalized_url) || "document"
          value -> value
        end

      %{url: normalized_url, file_name: resolved_name}
    else
      _ -> nil
    end
  end

  defp normalize_explicit_attachment(_), do: nil

  defp derive_file_name_from_url(url) when is_binary(url) do
    url
    |> String.split("?")
    |> List.first()
    |> to_string()
    |> Path.basename()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp derive_file_name_from_url(_), do: nil

  defp sanitize_agent_plain_text(text, attachment) do
    normalized = text |> to_string()

    stripped =
      normalized
      |> strip_upload_links()
      |> maybe_strip_remaining_links(attachment)
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    cond do
      stripped != "" ->
        stripped

      attachment && is_map(attachment) ->
        "Document attached."

      true ->
        "Agent response"
    end
  end

  defp strip_upload_links(text) do
    text
    |> String.replace(~r/https?:\/\/[^\s)]*\/api\/agent\/document\/[^\s)]+/i, "")
    |> String.replace(~r/\/api\/agent\/document\/[^\s)]+/i, "")
    |> String.replace(~r/https?:\/\/[^\s)]*\/uploads\/agent-docs\/[^\s)]+/i, "")
    |> String.replace(~r/\/uploads\/agent-docs\/[^\s)]+/i, "")
    |> String.replace(~r/\[([^\]]+)\]\(\s*\)/, "\\1")
    |> String.trim()
  end

  defp maybe_strip_remaining_links(text, attachment) when is_map(attachment) do
    text
    |> String.replace(~r/https?:\/\/[^\s)]+/i, "")
    |> String.replace(~r/\[([^\]]+)\]\(\s*\)/, "\\1")
    |> String.trim()
  end

  defp maybe_strip_remaining_links(text, _attachment), do: text


  defp maybe_compact(chat_id, user_id) do
    Task.start(fn ->
      case GroupAgentMemory.get_or_create(chat_id, acting_user_id: user_id) do
        {:ok, memory} when length(memory.messages) > @compaction_threshold ->
          compact_memory(memory, user_id)

        _ ->
          :ok
      end
    end)
  end

  defp compact_memory(memory, user_id) do
    messages = memory.messages
    to_compact = Enum.take(messages, length(messages) - @keep_recent_count)
    to_keep = Enum.take(messages, -@keep_recent_count)

    conversation_text =
      to_compact
      |> Enum.map(fn msg ->
        role = if msg["role"] == "assistant", do: "Agent", else: "User"
        "#{role}: #{msg["content"]}"
      end)
      |> Enum.join("\n")

    existing_summary = memory.summary || ""

    prompt = """
    Summarize this group chat conversation concisely, preserving key facts, decisions, data, and context that would be needed to continue the conversation. Include specific numbers, names, and commitments.

    #{if existing_summary != "", do: "Previous summary:\n#{existing_summary}\n\nNew messages to incorporate:", else: "Conversation:"}

    #{conversation_text}

    Provide a concise summary (max 500 words):
    """

    case Vibe.AI.Agent.quick_completion(prompt) do
      {:ok, summary} ->
        GroupAgentMemory.update_after_compaction(
          memory,
          String.trim(summary),
          to_keep,
          acting_user_id: user_id
        )

        Logger.info(
          "[GroupAgent] Memory compacted for chat #{memory.chat_id}: #{length(to_compact)} messages summarized"
        )

      {:error, reason} ->
        Logger.error(
          "[GroupAgent] Memory compaction failed for chat #{memory.chat_id}: #{inspect(reason)}"
        )
    end
  end
end
