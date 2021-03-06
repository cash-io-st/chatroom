defmodule Chat.RoomChannel do
  use Phoenix.Channel
  use Chat.Web, :channel
  require Logger

  def join("rooms:lobby", _message, socket) do
    Process.flag(:trap_exit, true)
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("rooms:" <> _private_subtopic, _message, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def terminate(reason, _socket) do
    Logger.debug"> leave #{inspect reason}"
    :ok
  end

  def handle_info(:after_join, socket) do
    {:ok, history} = Redis.command(~w(ZRANGE history -30 -1))
    push socket, "history:msgs", %{ history: history }
    push socket, "join", %{status: "connected"}
    {:noreply, socket}
  end

  def handle_in("update:top:notice", msg, socket) do
    Redis.command(["SET","chatroom:top:notice","#{msg["notice"]}"])
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "update_top_notice"}
    {:noreply, socket}
  end

  def handle_in("add:bad_words", msg, socket) do
    Redis.command(["SADD","bad_words","#{msg["word"]}"])
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "add_bad_word"}
    {:noreply, socket}
  end

  def handle_in("reset:role", msg, socket) do
    Redis.command(~w(DEL #{msg["userNumber"]}:role ))
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "reset_role"}
    {:noreply, socket}
  end

  def handle_in("auth:beginner", msg, socket) do
    set_role("beginner", msg["userNumber"])
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "auth_beginner"}
    {:noreply, socket}
  end

  def handle_in("auth:helpful_user", msg, socket) do
    set_role("helpful_user", msg["userNumber"])
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "auth_helpful_user"}
    {:noreply, socket}
  end

  def handle_in("auth:advanced_user", msg, socket) do
    set_role("advanced_user", msg["userNumber"])
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "auth_advanced_user" }
    {:noreply, socket}
  end

  def handle_in("auth:certified_guest", msg, socket) do
    set_role("certified_guest", msg["userNumber"])
    push socket, "new:msg", %{name: socket.assigns[:username],is_admin: socket.assigns[:is_admin], action: "auth_certified_guest" }
    {:noreply, socket}
  end

  def handle_in("ban", msg, socket) do
    {:ok, ban_name} = Redis.command(~w(GET #{msg["userNumber"]}:name))
    Redis.command(~w(SET #{msg["userNumber"]}:ban #{msg["reason"]} ))
    Redis.command(~w(EXPIRE #{msg["userNumber"]}:ban #{String.to_integer(msg["minutes"])*60}))
    broadcast! socket, "new:msg", %{name: socket.assigns[:username], is_admin: socket.assigns[:is_admin], action: "ban", ban_name: ban_name }
    {:noreply, socket}
  end

  def handle_in("remove:ban", msg, socket) do
    {:ok, ban_name} = Redis.command(~w(GET #{msg["userNumber"]}:name))
    Redis.command(~w(EXPIRE #{msg["userNumber"]}:ban 0))
    push socket, "new:msg", %{name: socket.assigns[:username], is_admin: socket.assigns[:is_admin], action: "remove_ban", ban_name: ban_name }
    {:noreply, socket}
  end

  def handle_in("view:ban_reason", msg, socket) do
    {:ok, reason} = Redis.command(~w(GET #{msg["userNumber"]}:ban ))
    push socket, "new:msg", %{name: socket.assigns[:username], is_admin: socket.assigns[:is_admin], body: reason}
    {:noreply, socket}
  end

  def handle_in("new:msg", msg, socket) do
    {:ok, ban_time} = Redis.command(~w(TTL #{socket.assigns[:user_number]}:ban))
    ban_talk(ban_time, msg, socket)
  end

  defp ban_talk(ban_time, msg, socket) when ban_time < 0 do 
    {:ok, bad_words} = Redis.command(~w(SMEMBERS bad_words))
    clean_content = replace_bad_words(bad_words, msg["body"])
    if socket.assigns[:is_admin] == false do
      if socket.assigns[:username] == "用户" || socket.assigns[:username] == "Member" || contain_bad_words(bad_words, socket.assigns[:username]) do
        push socket, "new:msg", %{name: gettext("admin"), is_admin: "true", body: gettext("Your nickname includes sensitive words, please visit accounts page to change your nickname before making a statement.")}
        {:stop, %{reason: "nickname validate"}, :ok, socket}
      else
        {:ok, last_timestamp} = Redis.command(~w(HMGET #{socket.assigns[:user_number]} timestamp))
        if List.first(last_timestamp) && (timestamp()-String.to_integer(List.first(last_timestamp))) < 5 do
          push socket, "new:msg", %{name: gettext("admin"), is_admin: "true", body: gettext("Every five seconds made a statement.")}
          {:stop, %{reason: "talk too often"}, :ok, socket}
        else
          if String.length(msg["body"]) > 100 do
            push socket, "new:msg", %{name: gettext("admin"), is_admin: "true", body: gettext("The length of the words can not be greater than 100.")}
            {:stop, %{reason: "talk words too long"}, :ok, socket}
          else
            {:ok, last_content} = Redis.command(~w(HMGET #{socket.assigns[:user_number]} content))
            check_repeat_words(clean_content, socket, last_content)
          end
        end
      end
    else
      broadcast_message(clean_content, socket)
    end
  end

  defp ban_talk(ban_time, _msg, socket) when ban_time > 0 do
    push socket, "new:msg", %{name: gettext("admin"), is_admin: "true", body: gettext("You can make a statement after %{hour} hours!", hour: "#{Float.round(ban_time/3600, 1)}")}
    {:stop, %{reason: "have been ban"}, :ok, socket}
  end

  def check_repeat_words(clean_content, socket, last_content) do
    if Base.encode64(clean_content) == List.first(last_content) do
      push socket, "new:msg", %{name: gettext("admin"), is_admin: "true", body: gettext("Repeated statements are forbidden.")}
      {:stop, %{reason: "repeat words"}, :ok, socket}
    else
      broadcast_message(clean_content, socket)
    end
  end

  def contain_bad_words([head | tail], nickname) do
    if String.contains?(nickname, head) do
      true
    else
      contain_bad_words(tail, nickname)
    end
  end

  def contain_bad_words([], _nickname) do
    false
  end

  def replace_bad_words([head | tail], content) do
    replace_bad_words(tail, String.replace(content, head, "**"))
  end

  def replace_bad_words([], content) do
    content
  end

  defp set_role(role, user_number) do
    Redis.command(~w(SET #{user_number}:role #{role}))
  end
  
  defp broadcast_message(clean_content, socket) do
    {:ok, role} = Redis.command(~w(get #{socket.assigns[:user_number]}:role))
    if is_tag() do
      value = "{'name':'SYSTEM','timestamp':#{timestamp()-1}}"
      Redis.command(~w(ZADD history #{timestamp()-1} #{Base.encode64(value)}))
      broadcast! socket, "new:msg", %{name: "SYSTEM",timestamp: timestamp()-1}
    end
    Redis.command(~w(HMSET #{socket.assigns[:user_number]} timestamp #{timestamp()} content #{Base.encode64(clean_content)}))
    value = "{'name':'#{socket.assigns[:username]}','number':'#{socket.assigns[:user_number]}','role':'#{role}','is_admin':#{socket.assigns[:is_admin]},'body':'#{clean_content}','timestamp':#{timestamp()}}"
    Redis.command(~w(ZADD history #{timestamp()} #{Base.encode64(value)}))
    broadcast! socket, "new:msg", %{name: socket.assigns[:username], number: socket.assigns[:user_number], is_admin: socket.assigns[:is_admin], body: clean_content, role: role, timestamp: timestamp()}
    {:reply, :ok, socket}
  end

  #show timestamp
  def is_tag do
    case Redis.command(~w(ZRANGE history -2 -1 WITHSCORES)) do
      {:ok, []} -> false
      {:ok, [_last_score, _last_member]} -> false
      {:ok, [_last_but_one_member, last_but_one_score, _last_member, last_score]} ->
        String.to_integer(last_score) - String.to_integer(last_but_one_score) > 120   
    end
  end

  def timestamp do
    :os.system_time(:seconds)
  end

end
