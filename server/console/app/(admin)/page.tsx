"use client";

import { useEffect, useState } from "react";

import { Alert, Card, PageTitle, Spinner } from "@/components/ui";
import { api, errorText, type Stats } from "@/lib/api";

function Stat({ label, value, hint }: { label: string; value: number | string; hint?: string }) {
  return (
    <div className="rounded-2xl bg-surface p-5 shadow-sm ring-1 ring-line/60">
      <div className="text-sm text-dim">{label}</div>
      <div className="mt-2 text-3xl font-bold tabular-nums">{value}</div>
      {hint && <div className="mt-1 text-xs text-dim">{hint}</div>}
    </div>
  );
}

function Breakdown({ data }: { data: Record<string, number> }) {
  const total = Object.values(data).reduce((a, b) => a + b, 0) || 1;
  const rows = Object.entries(data).sort((a, b) => b[1] - a[1]);
  if (!rows.length) return <p className="text-sm text-dim">Chưa có dữ liệu.</p>;
  return (
    <ul className="space-y-3">
      {rows.map(([k, v]) => (
        <li key={k}>
          <div className="mb-1 flex justify-between text-sm">
            <span className="capitalize">{k}</span>
            <span className="tabular-nums text-dim">{v}</span>
          </div>
          <div className="h-2 rounded-full bg-surface-hi">
            <div className="h-2 rounded-full bg-accent" style={{ width: `${(v / total) * 100}%` }} />
          </div>
        </li>
      ))}
    </ul>
  );
}

export default function Dashboard() {
  const [s, setS] = useState<Stats | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api<Stats>("/stats").then(setS).catch((e) => setError(errorText(e)));
  }, []);
  if (error) return <Alert>{error}</Alert>;
  if (!s) return <Spinner />;
  const max = Math.max(1, ...s.signups_daily.map((d) => d.count));

  return (
    <>
      <PageTitle title="Tổng quan" subtitle="Tình trạng người dùng và dữ liệu đồng bộ" />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Stat label="Người dùng" value={s.users} hint={`+${s.new_7d} trong 7 ngày`} />
        <Stat label="Hoạt động 7 ngày" value={s.active_7d} />
        <Stat label="Thiết bị đăng nhập" value={s.devices} />
        <Stat label="Vault đã tạo" value={s.vaults} hint={`${s.items} mục đã mã hoá`} />
      </div>
      <div className="mt-4 grid items-start gap-4 lg:grid-cols-3">
        <Card title="Đăng ký 30 ngày qua" className="lg:col-span-2">
          <div className="flex h-56 items-end gap-1">
            {s.signups_daily.map((d) => (
              <div key={d.day} className="group relative flex h-full flex-1 items-end">
                <div
                  className="w-full rounded-t bg-accent/80 transition group-hover:bg-accent"
                  style={{ height: `${Math.max(d.count ? 4 : 1, (d.count / max) * 100)}%`, opacity: d.count ? 1 : 0.25 }}
                />
                <div className="pointer-events-none absolute bottom-full left-1/2 mb-1 hidden -translate-x-1/2 whitespace-nowrap rounded-md bg-fg px-2 py-1 text-xs text-bg group-hover:block">
                  {d.day.slice(5)}: {d.count}
                </div>
              </div>
            ))}
          </div>
          <div className="mt-2 flex justify-between text-xs text-dim">
            <span>{s.signups_daily[0]?.day.slice(5)}</span>
            <span>Hôm nay</span>
          </div>
        </Card>
        <div className="space-y-4">
          <Card title="Theo gói">
            <Breakdown data={s.by_plan} />
          </Card>
          <Card title="Cách đăng nhập">
            <Breakdown data={s.by_provider} />
          </Card>
        </div>
      </div>
      {s.disabled > 0 && <p className="mt-4 text-sm text-dim">{s.disabled} tài khoản đang bị khoá.</p>}
    </>
  );
}
