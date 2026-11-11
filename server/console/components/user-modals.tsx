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
      onDone(`New password set for ${user.email}${revoke ? " and all devices signed out" : ""}.`);
    } catch (e) {
      setErr(errorText(e));
      setBusy(false);
    }
  };

  return (
    <Modal
      title="Reset password"
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button busy={busy} disabled={pw.length < 8} onClick={submit}>
            Set password
          </Button>
        </>
      }
    >
      <p className="text-sm text-dim">
        New sign-in password for <span className="font-medium text-fg">{user.email}</span>. Send it to the user over a
        secure channel.
      </p>
      <Field label="New password" hint="At least 8 characters.">
        <div className="flex gap-1.5">
          <Input value={pw} onChange={(e) => setPw(e.target.value)} className="font-mono" autoComplete="off" spellCheck={false} />
          <IconButton label="Generate random" onClick={() => setPw(randomPassword())} className="size-9.5 shrink-0">
            <Icon name="dice" />
          </IconButton>
          <IconButton label={copied ? "Copied" : "Copy"} onClick={copy} className="size-9.5 shrink-0">
            <Icon name="copy" />
          </IconButton>
        </div>
      </Field>
      <Toggle checked={revoke} onChange={setRevoke} label="Sign out all of the user's devices" />
      <Alert tone="amber">The vault password (E2EE) does not change: the user still unlocks synced data with their existing vault password or recovery key.</Alert>
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
        `Moved ${user.email} to the ${chosen?.name ?? planId} plan` +
          (expires ? `, expires ${fmtDate(expires, false)}.` : ", no expiry."),
      );
    } catch (e) {
      setErr(errorText(e));
      setBusy(false);
    }
  };

  return (
    <Modal
      title="Change plan / expiry"
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button busy={busy} disabled={hasEnd && !chosen?.is_default && !end} onClick={submit}>
            Save
          </Button>
        </>
      }
    >
      <p className="text-sm text-dim">
        <span className="font-medium text-fg">{user.email}</span>
        {user.plan_expires_at && (
          <>
            {" · "}
            {planExpired(user) ? "current plan expired" : "expires"} {fmtDate(user.plan_expires_at, false)}
          </>
        )}
      </p>
      <Field label="Plan">
        <Select value={planId} onChange={(e) => setPlanId(e.target.value)}>
          {plans.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name} {p.max_devices ? `(${p.max_devices} devices)` : "(unlimited devices)"}
              {p.is_default ? " · default" : ""}
            </option>
          ))}
        </Select>
      </Field>
      {chosen?.is_default ? (
        <p className="text-sm text-dim">The default plan has no expiry.</p>
      ) : (
        <>
          <Toggle checked={hasEnd} onChange={setHasEnd} label="Has an expiry date" />
          {hasEnd && (
            <>
              <Field
                label="Expires at the end of"
                hint={`After this day the account falls back to the ${def?.name ?? "default"} plan. The assigned plan is kept so it can be renewed.`}
              >
                <Input type="date" value={end} onChange={(e) => setEnd(e.target.value)} />
              </Field>
              <div className="flex flex-wrap gap-2">
                {[
                  [1, "+1 month"],
                  [3, "+3 months"],
                  [6, "+6 months"],
                  [12, "+1 year"],
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
