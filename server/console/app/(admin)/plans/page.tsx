"use client";

import { useCallback, useEffect, useState } from "react";

import { Alert, Badge, Button, Card, Field, Input, PageTitle, Spinner, Toggle } from "@/components/ui";
import { api, errorText, type Plan } from "@/lib/api";

const blank: Plan = { id: "", name: "", description: "", max_devices: 0, sync_enabled: true, is_default: false, sort_order: 0, users: 0 };

export default function PlansPage() {
  const [plans, setPlans] = useState<Plan[] | null>(null);
  const [edit, setEdit] = useState<Plan | null>(null);
  const [isNew, setIsNew] = useState(false);
  const [msg, setMsg] = useState<{ tone: "red" | "green"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    api<{ plans: Plan[] }>("/plans").then((r) => setPlans(r.plans)).catch((e) => setMsg({ tone: "red", text: errorText(e) }));
  }, []);
  useEffect(load, [load]);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!edit) return;
    setBusy(true);
    setMsg(null);
    try {
      await api(`/plans/${encodeURIComponent(edit.id)}`, { method: "PUT", body: edit });
      setMsg({ tone: "green", text: `Đã lưu gói ${edit.name}.` });
      setEdit(null);
      load();
    } catch (err) {
      setMsg({ tone: "red", text: errorText(err) });
    } finally {
      setBusy(false);
    }
  };

  const remove = async (p: Plan) => {
    if (!confirm(`Xoá gói ${p.name}?`)) return;
    setMsg(null);
    try {
      await api(`/plans/${p.id}`, { method: "DELETE" });
      load();
    } catch (err) {
      setMsg({ tone: "red", text: errorText(err) });
    }
  };

  if (!plans) return msg ? <Alert>{msg.text}</Alert> : <Spinner />;

  return (
    <>
      <PageTitle
        title="Gói dịch vụ"
        subtitle="Giới hạn áp dụng cho người dùng. Chưa có thanh toán: admin đổi gói cho từng người ở trang Người dùng."
        actions={
          <Button
            onClick={() => {
              setEdit({ ...blank, sort_order: plans.length });
              setIsNew(true);
            }}
          >
            + Thêm gói
          </Button>
        }
      />
      {msg && (
        <div className="mb-4">
          <Alert tone={msg.tone}>{msg.text}</Alert>
        </div>
      )}
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {plans.map((p) => (
          <Card key={p.id}>
            <div className="flex items-start justify-between gap-2">
              <div>
                <div className="flex items-center gap-2">
                  <h3 className="text-lg font-semibold">{p.name}</h3>
                  {p.is_default && <Badge tone="green">mặc định</Badge>}
                </div>
                <div className="font-mono text-xs text-dim">{p.id}</div>
              </div>
              <span className="text-sm text-dim">{p.users} người dùng</span>
            </div>
            {p.description && <p className="mt-3 text-sm text-dim">{p.description}</p>}
            <ul className="mt-4 space-y-1.5 text-sm">
              <li>Thiết bị: {p.max_devices ? `tối đa ${p.max_devices}` : "không giới hạn"}</li>
              <li>Sync: {p.sync_enabled ? "có" : "không"}</li>
            </ul>
            <div className="mt-5 flex gap-2">
              <Button
                variant="ghost"
                onClick={() => {
                  setEdit({ ...p });
                  setIsNew(false);
                }}
              >
                Sửa
              </Button>
              {!p.is_default && (
                <Button variant="danger" onClick={() => remove(p)}>
                  Xoá
                </Button>
              )}
            </div>
          </Card>
        ))}
      </div>

      {edit && (
        <div className="fixed inset-0 z-40 grid place-items-center bg-black/40 p-4" onClick={() => setEdit(null)}>
          <form onSubmit={save} onClick={(e) => e.stopPropagation()} className="w-full max-w-md space-y-4 rounded-2xl bg-surface p-6 shadow-xl">
            <h2 className="text-lg font-semibold">{isNew ? "Thêm gói" : `Sửa gói ${edit.name}`}</h2>
            {isNew && (
              <Field label="Mã gói" hint="Chữ thường, số, - và _. Không đổi được sau khi tạo.">
                <Input required pattern="[a-z0-9][a-z0-9_-]{0,31}" value={edit.id} onChange={(e) => setEdit({ ...edit, id: e.target.value })} />
              </Field>
            )}
            <Field label="Tên hiển thị">
              <Input required value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} />
            </Field>
            <Field label="Mô tả">
              <Input value={edit.description} onChange={(e) => setEdit({ ...edit, description: e.target.value })} />
            </Field>
            <Field label="Số thiết bị tối đa" hint="0 = không giới hạn. Áp dụng khi đăng nhập trên thiết bị mới.">
              <Input
                type="number"
                min={0}
                value={edit.max_devices}
                onChange={(e) => setEdit({ ...edit, max_devices: Number(e.target.value) })}
              />
            </Field>
            <Toggle checked={edit.sync_enabled} onChange={(v) => setEdit({ ...edit, sync_enabled: v })} label="Cho phép sync dữ liệu" />
            <Toggle
              checked={edit.is_default}
              onChange={(v) => setEdit({ ...edit, is_default: v })}
              label="Gói mặc định cho người dùng mới"
            />
            <div className="flex justify-end gap-2 pt-2">
              <Button type="button" variant="ghost" onClick={() => setEdit(null)}>
                Huỷ
              </Button>
              <Button type="submit" busy={busy}>
                Lưu
              </Button>
            </div>
          </form>
        </div>
      )}
    </>
  );
}
