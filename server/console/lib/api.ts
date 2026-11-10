// Thin client for /api/v1/admin. Auth is an HttpOnly cookie set by /admin/login.

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public details?: Record<string, unknown>) {
    super(message);
  }
}

export async function api<T = unknown>(path: string, init: { method?: string; body?: unknown } = {}): Promise<T> {
  const res = await fetch(`/api/v1/admin${path}`, {
    method: init.method ?? "GET",
    credentials: "same-origin",
    headers: init.body !== undefined ? { "Content-Type": "application/json" } : undefined,
    body: init.body !== undefined ? JSON.stringify(init.body) : undefined,
  });
  if (res.status === 204) return undefined as T;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = data?.error ?? {};
    throw new ApiError(res.status, e.code ?? "error", e.message ?? res.statusText, e.details);
  }
  return data as T;
}

// Vietnamese messages for API error codes shown in the console.
const messages: Record<string, string> = {
  invalid_credentials: "Sai email hoặc mật khẩu.",
  forbidden: "Tài khoản này không có quyền quản trị.",
  account_disabled: "Tài khoản đã bị khoá.",
  rate_limited: "Thử quá nhiều lần, vui lòng đợi một lát.",
  last_admin: "Không thể hạ quyền hoặc khoá admin cuối cùng.",
  self_delete: "Không thể tự xoá tài khoản của chính mình trong console.",
  plan_default: "Không thể xoá hoặc bỏ mặc định gói đang là mặc định. Hãy đặt gói khác làm mặc định trước.",
  plan_in_use: "Gói đang có người dùng. Chuyển họ sang gói khác trước.",
  email_not_configured: "Chưa cấu hình SMTP. Nhập và lưu cấu hình SMTP trước.",
  email_send_failed: "Gửi email thất bại",
};

export function errorText(e: unknown): string {
  if (e instanceof ApiError) {
    const m = messages[e.code];
    if (m && e.code === "email_send_failed") return `${m}: ${e.message}`;
    return m ?? e.message;
  }
  return e instanceof Error ? e.message : String(e);
}

// ---- types (mirror the Go structs) ----

export type User = {
  id: string;
  email: string;
  email_verified: boolean;
  name: string;
  role: "user" | "admin";
  plan_id: string;
  disabled: boolean;
  created_at: string;
  last_seen_at: string | null;
};

export type UserListItem = User & { providers: string[]; has_vault: boolean; items: number };

export type Session = {
  id: string;
  kind: "app" | "console";
  auth_method: string;
  device_name: string;
  platform: string;
  ip: string;
  created_at: string;
  last_used_at: string;
  expires_at: string;
};

export type Plan = {
  id: string;
  name: string;
  description: string;
  max_devices: number;
  sync_enabled: boolean;
  is_default: boolean;
  sort_order: number;
  users: number;
};

export type Stats = {
  users: number;
  new_7d: number;
  active_7d: number;
  disabled: number;
  vaults: number;
  items: number;
  devices: number;
  by_plan: Record<string, number>;
  by_provider: Record<string, number>;
  signups_daily: { day: string; count: number }[];
};

export type Settings = {
  general: { app_name: string; signup_enabled: boolean; support_email: string };
  smtp: { host: string; port: number; username: string; password: string; from: string; security: string };
  google: { enabled: boolean; client_ids: string[] };
  apple: { enabled: boolean; audiences: string[] };
};

export type AuditEntry = {
  id: number;
  at: string;
  actor_email: string | null;
  action: string;
  target: string;
  meta: Record<string, unknown>;
  ip: string;
};

export function fmtDate(s: string | null | undefined, withTime = true): string {
  if (!s) return "—";
  const d = new Date(s);
  return withTime
    ? d.toLocaleString("vi-VN", { dateStyle: "short", timeStyle: "short" })
    : d.toLocaleDateString("vi-VN");
}

export function timeAgo(s: string | null | undefined): string {
  if (!s) return "chưa";
  const sec = (Date.now() - new Date(s).getTime()) / 1000;
  if (sec < 60) return "vừa xong";
  if (sec < 3600) return `${Math.floor(sec / 60)} phút trước`;
  if (sec < 86400) return `${Math.floor(sec / 3600)} giờ trước`;
  if (sec < 30 * 86400) return `${Math.floor(sec / 86400)} ngày trước`;
  return fmtDate(s, false);
}
