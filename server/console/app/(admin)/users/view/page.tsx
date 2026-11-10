"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useCallback, useEffect, useState } from "react";

import { useAdmin } from "@/components/shell";
import { Alert, Badge, Button, Card, Empty, Field, PageTitle, Select, Spinner, Toggle } from "@/components/ui";
import { api, errorText, fmtDate, timeAgo, type Plan, type Session, type User } from "@/lib/api";

type Detail = {
  user: User;
  has_password: boolean;
  identities: { provider: string; email: string; created_at: string }[];
  sessions: Session[];
  vault: { exists: boolean; items?: number; created_at?: string; updated_at?: string };
};

function UserView() {
  const id = useSearchParams().get("id") ?? "";
  const router = useRouter();
  const me = useAdmin();
  const [d, setD] = useState<Detail | null>(null);
  const [plans, setPlans] = useState<Plan[]>([]);
  const [msg, setMsg] = useState<{ tone: "red" | "green"; text: string } | null>(null);
  const [busy, setBusy] = useState("");

  const load = useCallback(() => {
    api<Detail>(`/users/${id}`).then(setD).catch((e) => setMsg({ tone: "red", text: errorText(e) }));
  }, [id]);
  useEffect(() => {
    load();
    api<{ plans: Plan[] }>("/plans").then((r) => setPlans(r.plans)).catch(() => {});
  }, [load]);

  const run = async (key: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(key);
    setMsg(null);
    try {
      await fn();
      setMsg({ tone: "green", text: ok });
      load();
    } catch (e) {
      setMsg({ tone: "red", text: errorText(e) });
    } finally {
      setBusy("");
    }
  };
  const patch = (body: Partial<User>, ok: string) =>
    run("patch", () => api(`/users/${id}`, { method: "PATCH", body }), ok);

  if (!d) return msg ? <Alert>{msg.text}</Alert> : <Spinner />;
  const u = d.user;
  const self = u.id === me.id;

  return (
    <>
      <Link href="/users/" className="text-sm text-dim hover:text-fg">
        ← Người dùng
      </Link>
      <PageTitle
        title={u.email}
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            {u.name && <span>{u.name}</span>}
            {u.role === "admin" && <Badge tone="blue">admin</Badge>}
            {u.disabled && <Badge tone="red">đã khoá</Badge>}
            <span>Tạo {fmtDate(u.created_at)} · Hoạt động {timeAgo(u.last_seen_at)}</span>
          </span>
        }
      />
      {msg && (
        <div className="mb-4">
          <Alert tone={msg.tone}>{msg.text}</Alert>
        </div>
      )}
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Card title="Tài khoản">
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Gói dịch vụ" hint="Nâng cấp / hạ cấp có hiệu lực ngay.">
                <Select value={u.plan_id} disabled={busy !== ""} onChange={(e) => patch({ plan_id: e.target.value }, "Đã đổi gói.")}>
                  {plans.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} {p.max_devices ? `(${p.max_devices} thiết bị)` : "(không giới hạn)"}
                    </option>
                  ))}
                </Select>
              </Field>
              <Field label="Vai trò">
                <Select
                  value={u.role}
                  disabled={busy !== "" || self}
                  onChange={(e) => patch({ role: e.target.value as User["role"] }, "Đã đổi vai trò.")}
                >
                  <option value="user">Người dùng</option>
                  <option value="admin">Admin</option>
                </Select>
              </Field>
            </div>
            <div className="mt-4 border-t border-line pt-3">
              <Toggle
                checked={u.disabled}
                onChange={(v) => !self && patch({ disabled: v }, v ? "Đã khoá tài khoản và đăng xuất mọi thiết bị." : "Đã mở khoá.")}
                label={
                  <span>
                    Khoá tài khoản <span className="text-dim">— chặn đăng nhập và sync</span>
                  </span>
                }
              />
            </div>
          </Card>

          <Card
            title={`Phiên đăng nhập (${d.sessions.length})`}
            actions={
              d.sessions.length > 0 && (
                <Button
                  variant="ghost"
                  busy={busy === "revoke"}
                  onClick={() => run("revoke", () => api(`/users/${id}/revoke-sessions`, { method: "POST" }), "Đã đăng xuất mọi thiết bị.")}
                >
                  Đăng xuất tất cả
                </Button>
              )
            }
          >
            {d.sessions.length === 0 ? (
              <Empty>Không có phiên nào đang hoạt động.</Empty>
            ) : (
              <ul className="divide-y divide-line/60">
                {d.sessions.map((s) => (
                  <li key={s.id} className="flex items-center justify-between gap-3 py-3 text-sm">
                    <div>
                      <div className="font-medium">
                        {s.kind === "console" ? "Console" : s.device_name || "Thiết bị không tên"}{" "}
                        {s.platform && <span className="text-dim">· {s.platform}</span>}
                      </div>
                      <div className="text-xs text-dim">
                        {s.auth_method} · {s.ip} · tạo {fmtDate(s.created_at)}
                      </div>
                    </div>
                    <span className="text-xs text-dim">{timeAgo(s.last_used_at)}</span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>

        <div className="space-y-4">
          <Card title="Đăng nhập bằng">
            <ul className="space-y-2 text-sm">
              <li className="flex justify-between">
                <span>Email + mật khẩu</span>
                <span className="text-dim">{d.has_password ? "đã đặt" : "chưa đặt"}</span>
              </li>
              {d.identities.map((i) => (
                <li key={i.provider} className="flex justify-between gap-2">
                  <span className="capitalize">{i.provider}</span>
                  <span className="truncate text-dim">{i.email}</span>
                </li>
              ))}
            </ul>
          </Card>
          <Card title="Vault (E2EE)">
            {d.vault.exists ? (
              <div className="space-y-1 text-sm">
                <div>{d.vault.items} mục đã mã hoá</div>
                <div className="text-dim">Cập nhật {timeAgo(d.vault.updated_at)}</div>
                <p className="pt-2 text-xs text-dim">Server không thể đọc nội dung vault.</p>
              </div>
            ) : (
              <p className="text-sm text-dim">Chưa bật sync.</p>
            )}
          </Card>
          {!self && (
            <Card title="Vùng nguy hiểm">
              <p className="mb-3 text-sm text-dim">Xoá tài khoản cùng toàn bộ dữ liệu đã sync. Không thể hoàn tác.</p>
              <Button
                variant="danger"
                busy={busy === "delete"}
                onClick={() => {
                  if (!confirm(`Xoá vĩnh viễn ${u.email}?`)) return;
                  run("delete", () => api(`/users/${id}`, { method: "DELETE" }), "Đã xoá.").then(() => router.replace("/users/"));
                }}
              >
                Xoá tài khoản
              </Button>
            </Card>
          )}
        </div>
      </div>
    </>
  );
}

export default function Page() {
  return (
    <Suspense fallback={<Spinner />}>
      <UserView />
    </Suspense>
  );
}
