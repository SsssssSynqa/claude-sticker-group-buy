import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";

import {
  type ActiveAccount,
  authenticateAccount,
  corsHeaders,
  jsonResponse,
  normalizeName,
  publicErrorMessage,
  requireEnvironment,
  signAccountToken,
} from "../_shared/edge-auth.ts";

const { supabaseUrl, serviceRoleKey, customJwtSecret } = requireEnvironment();
const client = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});
const jwtSecret = new TextEncoder().encode(customJwtSecret);

function parsePin(value: unknown, label = "密码"): string {
  const pin = String(value ?? "");
  if (!/^\d{4,6}$/.test(pin)) throw new Error(`${label}必须是 4~6 位数字`);
  return pin;
}

function parseTeam(value: unknown): number {
  const team = Number(value);
  if (!Number.isInteger(team) || team < 1 || team > 6) {
    throw new Error("请选择有效的分团");
  }
  return team;
}

function accountResponse(account: ActiveAccount, token: string) {
  return {
    token,
    account_id: account.id,
    name: account.name_key,
    display_name: account.display_name,
    role: account.role,
    team: account.team,
  };
}

async function issueAccountResponse(account: ActiveAccount) {
  return accountResponse(account, await signAccountToken(account, jwtSecret));
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") {
    return jsonResponse(request, { error: "POST only" }, 405);
  }

  try {
    const body = await request.json();
    const action = String(body.action || "login");

    if (action === "register") {
      const name = String(body.name ?? "").trim();
      if (name.length < 1 || name.length > 50) throw new Error("昵称格式无效");
      if (
        ["null", "undefined", "nan", "true", "false"].includes(
          normalizeName(name),
        )
      ) {
        throw new Error("该昵称不可用");
      }
      const pin = parsePin(body.pin);
      const team = parseTeam(body.team);
      const { data, error } = await client.rpc("register_group_buy_account", {
        p_display_name: name,
        p_pin: pin,
        p_team: team,
      });
      if (error) {
        const conflict = error.code === "23505" ||
          /已被注册|collide/i.test(error.message);
        return jsonResponse(request, {
          error: conflict
            ? "该昵称已被注册，请登录或换一个昵称"
            : publicErrorMessage(error),
        }, conflict ? 409 : 400);
      }
      return jsonResponse(
        request,
        await issueAccountResponse(data as ActiveAccount),
      );
    }

    if (action === "login") {
      const name = String(body.name ?? "").trim();
      const pin = parsePin(body.pin);
      const { data, error } = await client.rpc(
        "authenticate_group_buy_account",
        {
          p_name: name,
          p_pin: pin,
        },
      );
      if (error) throw error;
      if (!data?.ok) {
        if (data?.code === "temporarily_locked") {
          return jsonResponse(request, {
            error: "密码错误次数过多，请 15 分钟后再试",
            retry_after_seconds: data.retry_after_seconds,
          }, 429);
        }
        if (data?.code === "account_disabled") {
          return jsonResponse(
            request,
            { error: "账号已停用，请联系团长" },
            403,
          );
        }
        return jsonResponse(request, { error: "昵称或密码错误" }, 401);
      }
      return jsonResponse(
        request,
        await issueAccountResponse(data.account as ActiveAccount),
      );
    }

    const account = await authenticateAccount(client, request, jwtSecret);
    if (!account) {
      return jsonResponse(request, { error: "未登录或登录已过期" }, 401);
    }

    if (action === "session") {
      return jsonResponse(request, {
        ok: true,
        ...(await issueAccountResponse(account)),
      });
    }

    if (action === "change_pin") {
      const oldPin = parsePin(body.old_pin, "原密码");
      const newPin = parsePin(body.new_pin, "新密码");
      const { data, error } = await client.rpc("change_group_buy_pin", {
        p_account_id: account.id,
        p_old_pin: oldPin,
        p_new_pin: newPin,
      });
      if (error) throw error;
      if (!data?.ok) {
        if (data?.code === "temporarily_locked") {
          return jsonResponse(request, {
            error: "密码错误次数过多，请 15 分钟后再试",
            retry_after_seconds: data.retry_after_seconds,
          }, 429);
        }
        return jsonResponse(request, { error: "原密码错误" }, 401);
      }
      const updated: ActiveAccount = {
        ...account,
        token_version: Number(data.token_version),
      };
      return jsonResponse(request, {
        ok: true,
        token: await signAccountToken(updated, jwtSecret),
      });
    }

    if (action === "change_team") {
      const team = parseTeam(body.team);
      const { data, error } = await client.rpc("change_group_buy_team", {
        p_account_id: account.id,
        p_team: team,
      });
      if (error) throw error;
      return jsonResponse(request, {
        ok: true,
        ...(await issueAccountResponse(data as ActiveAccount)),
      });
    }

    if (action === "rename") {
      const displayName = String(body.new_name ?? "").trim();
      if (displayName.length < 1 || displayName.length > 50) {
        throw new Error("昵称格式无效");
      }
      const { data: updated, error } = await client.rpc(
        "rename_group_buy_account",
        { p_account_id: account.id, p_display_name: displayName },
      );
      if (error) {
        if (error.code === "23505") {
          return jsonResponse(
            request,
            { error: "该显示昵称已被其他人使用" },
            409,
          );
        }
        throw error;
      }
      return jsonResponse(request, {
        ok: true,
        display_name: updated.display_name,
        token: await signAccountToken(updated as ActiveAccount, jwtSecret),
      });
    }

    return jsonResponse(request, { error: "不支持的操作" }, 400);
  } catch (error) {
    const message = publicErrorMessage(error);
    console.error("auth request failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    const validation = message !== "服务器处理失败";
    return jsonResponse(request, { error: message }, validation ? 400 : 500);
  }
});
