"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

import { Alert, Badge, Button, Card, Empty, Icon, IconButton, Input, PageTitle, Providers, Select, Spinner } from "@/components/ui";
import { PlanModal, ResetPasswordModal } from "@/components/user-modals";
import { api, errorText, fmtDate, planExpired, timeAgo, type Plan, type UserListItem } from "@/lib/api";

const PAGE = 25;

export default function UsersPage() {
  const [q, setQ] = useState("");
  const [plan, setPlan] = useState("");
  const [offset, setOffset] = useState(0);
  const [data, setData] = useState<{ users: UserListItem[]; total: number } | null>(null);
  const [plans, setPlans] = useState<Plan[]>([]);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [modal, setModal] = useState<{ kind: "password" | "plan"; user: UserListItem } | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    api<{ plans: Plan[] }>("/plans").then((r) => setPlans(r.plans)).catch(() => {});
  }, []);

  useEffect(() => {
    const t = setTimeout(() => {
      const p = new URLSearchParams({ q, plan, limit: String(PAGE), offset: String(offset) });
      api<{ users: UserListItem[]; total: number }>(`/users?${p}`)
        .then((r) => {
          setData(r);
          setError("");
        })
        .catch((e) => setError(errorText(e)));
    }, 250);
    return () => clearTimeout(t);
  }, [q, plan, offset, reload]);

  const done = (msg: string) => {
    setModal(null);
    setNotice(msg);
    setReload((n) => n + 1);
  };

  const planName = (id: string) => plans.find((p) => p.id === id)?.name ?? id;

  return (
    <>
      <PageTitle title="Users" subtitle={data ? `${data.total} accounts` : undefined} />
      <Card>
        <div className="mb-4 grid gap-3 sm:grid-cols-[minmax(0,20rem)_11rem]">
          <Input
            placeholder="Search by email or name…"
            value={q}
            onChange={(e) => {
              setQ(e.target.value);
              setOffset(0);
            }}
          />
          <Select
            value={plan}
            onChange={(e) => {
              setPlan(e.target.value);
              setOffset(0);
            }}
          >
            <option value="">All plans</option>
            {plans.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </Select>
        </div>
        {error && <Alert>{error}</Alert>}
        {notice && (
          <div className="mb-4">
            <Alert tone="green">{notice}</Alert>
          </div>
        )}
        {!data ? (
          <Spinner />
        ) : data.users.length === 0 ? (
          <Empty>No users.</Empty>
        ) : (
          <div className="-mx-5 overflow-x-auto">
            <table className="w-full min-w-[720px] text-sm">
              <thead>
                <tr className="border-b border-line text-left text-xs uppercase tracking-wide text-dim">
                  <th className="px-5 py-2 font-medium">Email</th>
                  <th className="px-3 py-2 font-medium">Sign-in</th>
                  <th className="px-3 py-2 font-medium">Plan</th>
                  <th className="px-3 py-2 font-medium">Sync</th>
                  <th className="px-3 py-2 font-medium">Last active</th>
                  <th className="px-5 py-2" />
                </tr>
              </thead>
              <tbody>
                {data.users.map((u) => (
                  <tr key={u.id} className="border-b border-line/60 last:border-0 hover:bg-surface-hi/40">
                    <td className="px-5 py-3">
                      <Link href={`/users/view/?id=${u.id}`} className="font-medium hover:text-accent">
                        {u.email}
                      </Link>
                      <div className="mt-0.5 flex gap-1.5">
                        {u.name && <span className="text-xs text-dim">{u.name}</span>}
                        {u.role === "admin" && <Badge tone="blue">admin</Badge>}
                        {u.disabled && <Badge tone="red">disabled</Badge>}
                      </div>
                    </td>
                    <td className="px-3 py-3">
                      <Providers list={u.providers} />
                    </td>
                    <td className="px-3 py-3">
                      <Badge tone={planExpired(u) ? "red" : u.plan_id === "free" ? "neutral" : "green"}>{planName(u.plan_id)}</Badge>
                      {u.plan_expires_at && (
                        <div className={`mt-0.5 text-xs ${planExpired(u) ? "text-red-600 dark:text-red-400" : "text-dim"}`}>
                          {planExpired(u) ? "expired" : "until"} {fmtDate(u.plan_expires_at, false)}
                        </div>
                      )}
                    </td>
                    <td className="px-3 py-3 text-dim">{u.has_vault ? `${u.items} items` : "—"}</td>
                    <td className="px-3 py-3 text-dim">{timeAgo(u.last_seen_at)}</td>
                    <td className="px-5 py-3">
                      <div className="flex justify-end gap-1">
                        <IconButton label="Change plan / expiry" onClick={() => setModal({ kind: "plan", user: u })}>
                          <Icon name="plan" />
                        </IconButton>
                        <IconButton label="Reset password" onClick={() => setModal({ kind: "password", user: u })}>
                          <Icon name="key" />
                        </IconButton>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {data && data.total > PAGE && (
          <div className="mt-4 flex items-center justify-between text-sm text-dim">
            <span>
              {offset + 1}–{Math.min(offset + PAGE, data.total)} / {data.total}
            </span>
            <div className="flex gap-2">
              <Button variant="ghost" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))}>
                Previous
              </Button>
              <Button variant="ghost" disabled={offset + PAGE >= data.total} onClick={() => setOffset(offset + PAGE)}>
                Next
              </Button>
            </div>
          </div>
        )}
      </Card>
      {modal?.kind === "password" && <ResetPasswordModal user={modal.user} onClose={() => setModal(null)} onDone={done} />}
      {modal?.kind === "plan" && <PlanModal user={modal.user} plans={plans} onClose={() => setModal(null)} onDone={done} />}
    </>
  );
}
