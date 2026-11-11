"use client";

import { useEffect, useState } from "react";

import { Alert, Button, Card, Empty, PageTitle, Spinner } from "@/components/ui";
import { api, errorText, fmtDate, type AuditEntry } from "@/lib/api";

const PAGE = 50;

const labels: Record<string, string> = {
  "user.signup": "Sign up",
  "user.password_set": "Set password",
  "user.deleted_self": "Deleted own account",
  "vault.created": "Created vault",
  "vault.rewrapped": "Changed vault password",
  "vault.reset": "Reset vault",
  "admin.login": "Admin sign-in",
  "admin.user_update": "Updated user",
  "admin.user_delete": "Deleted user",
  "admin.user_revoke_sessions": "Signed out all devices",
  "admin.plan_save": "Saved plan",
  "admin.plan_delete": "Deleted plan",
  "admin.settings_update": "Updated settings",
};

function meta(m: Record<string, unknown>) {
  const parts = Object.entries(m)
    .filter(([, v]) => v !== null && v !== undefined)
    .map(([k, v]) => `${k}=${typeof v === "object" ? JSON.stringify(v) : String(v)}`);
  return parts.join(" · ");
}

export default function AuditPage() {
  const [offset, setOffset] = useState(0);
  const [data, setData] = useState<{ entries: AuditEntry[]; total: number } | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api<{ entries: AuditEntry[]; total: number }>(`/audit?limit=${PAGE}&offset=${offset}`)
      .then(setData)
      .catch((e) => setError(errorText(e)));
  }, [offset]);

  return (
    <>
      <PageTitle title="Audit log" subtitle="Important user and admin actions" />
      {error && <Alert>{error}</Alert>}
      <Card>
        {!data ? (
          <Spinner />
        ) : data.entries.length === 0 ? (
          <Empty>Nothing yet.</Empty>
        ) : (
          <div className="-mx-5 overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead>
                <tr className="border-b border-line text-left text-xs uppercase tracking-wide text-dim">
                  <th className="px-5 py-2 font-medium">Time</th>
                  <th className="px-3 py-2 font-medium">Action</th>
                  <th className="px-3 py-2 font-medium">Actor</th>
                  <th className="px-3 py-2 font-medium">Target</th>
                  <th className="px-3 py-2 font-medium">IP</th>
                </tr>
              </thead>
              <tbody>
                {data.entries.map((e) => (
                  <tr key={e.id} className="border-b border-line/60 align-top last:border-0">
                    <td className="whitespace-nowrap px-5 py-2.5 text-dim">{fmtDate(e.at)}</td>
                    <td className="px-3 py-2.5">
                      <div>{labels[e.action] ?? e.action}</div>
                      {Object.keys(e.meta ?? {}).length > 0 && <div className="font-mono text-xs text-dim">{meta(e.meta)}</div>}
                    </td>
                    <td className="px-3 py-2.5">{e.actor_email ?? "—"}</td>
                    <td className="px-3 py-2.5">{e.target || "—"}</td>
                    <td className="px-3 py-2.5 font-mono text-xs text-dim">{e.ip}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {data && data.total > PAGE && (
          <div className="mt-4 flex justify-end gap-2">
            <Button variant="ghost" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))}>
              Newer
            </Button>
            <Button variant="ghost" disabled={offset + PAGE >= data.total} onClick={() => setOffset(offset + PAGE)}>
              Older
            </Button>
          </div>
        )}
      </Card>
    </>
  );
}
