"use client";

import { useState } from "react";

import { Alert, Button, Field, Icon, IconButton, Input, Modal, Select, Toggle } from "@/components/ui";
import { api, errorText, fmtDate, planExpired, type Plan, type User } from "@/lib/api";

type Target = Pick<User, "id" | "email" | "plan_id" | "plan_expires_at">;

/** 16 random characters from an alphabet without look-alikes (0/O, 1/l/I). */
function randomPassword(): string {
  const abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const b = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(b, (x) => abc[x % abc.length]).join("");
}

export function ResetPasswordModal({ user, onClose, onDone }: { user: Target; onClose: () => void; onDone: (msg: string) => void }) {
  const [pw, setPw] = useState(randomPassword);
  const [revoke, setRevoke] = useState(true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    await navigator.clipboard.writeText(pw);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  const submit = async () => {
    setBusy(true);
    setErr("");
    try {
      await api(`/users/${user.id}/password`, { method: "POST", body: { password: pw, revoke_sessions: revoke } });
      onDone(`Đã đặt mật khẩu mới cho ${user.email}${revoke ? " và đăng xuất mọi thiết bị" : ""}.`);
    } catch (e) {
      setErr(errorText(e));
      setBusy(false);
    }
  };

  return (
    <Modal
      title="Đặt lại mật khẩu"
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Huỷ
          </Button>
          <Button busy={busy} disabled={pw.length < 8} onClick={submit}>
            Đặt mật khẩu
          </Button>
        </>
      }
    >
      <p className="text-sm text-dim">
        Mật khẩu đăng nhập mới cho <span className="font-medium text-fg">{user.email}</span>. Gửi mật khẩu này cho người dùng
        qua kênh an toàn.
      </p>
      <Field label="Mật khẩu mới" hint="Ít nhất 8 ký tự.">
        <div className="flex gap-1.5">
          <Input value={pw} onChange={(e) => setPw(e.target.value)} className="font-mono" autoComplete="off" spellCheck={false} />
          <IconButton label="Tạo ngẫu nhiên" onClick={() => setPw(randomPassword())} className="size-9.5 shrink-0">
            <Icon name="dice" />
          </IconButton>
          <IconButton label={copied ? "Đã copy" : "Copy"} onClick={copy} className="size-9.5 shrink-0">
            <Icon name="copy" />
          </IconButton>
        </div>
      </Field>
      <Toggle checked={revoke} onChange={setRevoke} label="Đăng xuất mọi thiết bị của người dùng" />
      <Alert tone="amber">Mật khẩu vault (E2EE) không đổi: người dùng vẫn mở dữ liệu đã sync bằng mật khẩu vault hoặc recovery key cũ.</Alert>
      {err && <Alert>{err}</Alert>}
    </Modal>
  );
}

/** Value for <input type="date"> in local time. */
function toDateInput(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** The plan ends at the end of the chosen day, local time. */
function endOfDay(v: string): Date {
  const [y, m, d] = v.split("-").map(Number);
  return new Date(y, m - 1, d, 23, 59, 59);
}

export function PlanModal({
  user,
  plans,
  onClose,
  onDone,
}: {
  user: Target;
  plans: Plan[];
  onClose: () => void;
  onDone: (msg: string) => void;
}) {
  const [planId, setPlanId] = useState(user.plan_id);
  const [hasEnd, setHasEnd] = useState(!!user.plan_expires_at);
  const [end, setEnd] = useState(() =>
    toDateInput(user.plan_expires_at ? new Date(user.plan_expires_at) : new Date(Date.now() + 30 * 86400e3)),
  );
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const def = plans.find((p) => p.is_default);
  const chosen = plans.find((p) => p.id === planId);

  // Extend from the current end date if it's still ahead, otherwise from today.
  const extend = (months: number) => {
    const cur = user.plan_expires_at && !planExpired(user) ? new Date(user.plan_expires_at) : new Date();
    const d = new Date(cur);
    d.setMonth(d.getMonth() + months);
    setHasEnd(true);
    setEnd(toDateInput(d));
  };

  const submit = async () => {
    setBusy(true);
    setErr("");
    try {
      const expires = hasEnd && !chosen?.is_default ? endOfDay(end).toISOString() : null;
      await api(`/users/${user.id}`, { method: "PATCH", body: { plan_id: planId, plan_expires_at: expires } });
      onDone(
        `Đã chuyển ${user.email} sang gói ${chosen?.name ?? planId}` +
          (expires ? `, hết hạn ${fmtDate(expires, false)}.` : ", không thời hạn."),
      );
    } catch (e) {
      setErr(errorText(e));
      setBusy(false);
    }
  };

  return (
    <Modal
      title="Gói dịch vụ"
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Huỷ
          </Button>
          <Button busy={busy} disabled={hasEnd && !chosen?.is_default && !end} onClick={submit}>
            Lưu
          </Button>
        </>
      }
    >
      <p className="text-sm text-dim">
        <span className="font-medium text-fg">{user.email}</span>
        {user.plan_expires_at && (
          <>
            {" · "}
            {planExpired(user) ? "gói hiện tại đã hết hạn" : "hết hạn"} {fmtDate(user.plan_expires_at, false)}
          </>
        )}
      </p>
      <Field label="Gói">
        <Select value={planId} onChange={(e) => setPlanId(e.target.value)}>
          {plans.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name} {p.max_devices ? `(${p.max_devices} thiết bị)` : "(không giới hạn thiết bị)"}
              {p.is_default ? " · mặc định" : ""}
            </option>
          ))}
        </Select>
      </Field>
      {chosen?.is_default ? (
        <p className="text-sm text-dim">Gói mặc định không có thời hạn.</p>
      ) : (
        <>
          <Toggle checked={hasEnd} onChange={setHasEnd} label="Có ngày hết hạn" />
          {hasEnd && (
            <>
              <Field
                label="Hết hạn vào cuối ngày"
                hint={`Sau ngày này tài khoản tự về gói ${def?.name ?? "mặc định"}. Gói đã gán vẫn được giữ để gia hạn.`}
              >
                <Input type="date" value={end} onChange={(e) => setEnd(e.target.value)} />
              </Field>
              <div className="flex flex-wrap gap-2">
                {[
                  [1, "+1 tháng"],
                  [3, "+3 tháng"],
                  [6, "+6 tháng"],
                  [12, "+1 năm"],
                ].map(([m, label]) => (
                  <Button key={m} variant="ghost" className="px-3 py-1.5 text-xs" onClick={() => extend(m as number)}>
                    {label}
                  </Button>
                ))}
              </div>
            </>
          )}
        </>
      )}
      {err && <Alert>{err}</Alert>}
    </Modal>
  );
}
