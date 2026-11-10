"use client";

import { useEffect, useState } from "react";

import { useAdmin } from "@/components/shell";
import { Alert, Button, Card, Field, Input, PageTitle, Select, Spinner, Toggle } from "@/components/ui";
import { api, errorText, type Settings } from "@/lib/api";

type Resp = { settings: Settings; dev_mode: boolean; public_url: string };

function ListInput({ value, onChange, placeholder }: { value: string[]; onChange: (v: string[]) => void; placeholder: string }) {
  return (
    <textarea
      rows={3}
      placeholder={placeholder}
      value={(value ?? []).join("\n")}
      onChange={(e) => onChange(e.target.value.split("\n"))}
      className="w-full rounded-xl border border-line bg-bg px-3 py-2 font-mono text-xs outline-none focus:border-accent focus:ring-2 focus:ring-accent/25"
    />
  );
}

export default function SettingsPage() {
  const me = useAdmin();
  const [r, setR] = useState<Resp | null>(null);
  const [s, setS] = useState<Settings | null>(null);
  const [msg, setMsg] = useState<{ tone: "red" | "green"; text: string } | null>(null);
  const [busy, setBusy] = useState("");
  const [testTo, setTestTo] = useState(me.email);

  useEffect(() => {
    api<Resp>("/settings")
      .then((x) => {
        setR(x);
        setS(x.settings);
      })
      .catch((e) => setMsg({ tone: "red", text: errorText(e) }));
  }, []);

  if (!s || !r) return msg ? <Alert>{msg.text}</Alert> : <Spinner />;

  const set = <K extends keyof Settings>(k: K, v: Partial<Settings[K]>) => setS({ ...s, [k]: { ...s[k], ...v } });

  const save = async () => {
    setBusy("save");
    setMsg(null);
    try {
      const x = await api<Resp>("/settings", { method: "PUT", body: s });
      setS(x.settings);
      setMsg({ tone: "green", text: "Đã lưu cấu hình." });
    } catch (e) {
      setMsg({ tone: "red", text: errorText(e) });
    } finally {
      setBusy("");
    }
  };

  const testEmail = async () => {
    setBusy("test");
    setMsg(null);
    try {
      await api("/settings/test-email", { method: "POST", body: { to: testTo } });
      setMsg({ tone: "green", text: `Đã gửi email thử tới ${testTo}.` });
    } catch (e) {
      setMsg({ tone: "red", text: errorText(e) });
    } finally {
      setBusy("");
    }
  };

  return (
    <>
      <PageTitle
        title="Cấu hình"
        subtitle="Thay đổi có hiệu lực ngay, không cần khởi động lại server."
        actions={
          <Button onClick={save} busy={busy === "save"}>
            Lưu cấu hình
          </Button>
        }
      />
      {msg && (
        <div className="mb-4">
          <Alert tone={msg.tone}>{msg.text}</Alert>
        </div>
      )}
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Chung">
          <div className="space-y-4">
            <Field label="Tên ứng dụng" hint="Dùng trong email gửi mã xác thực.">
              <Input value={s.general.app_name} onChange={(e) => set("general", { app_name: e.target.value })} />
            </Field>
            <Field label="Email hỗ trợ">
              <Input type="email" value={s.general.support_email} onChange={(e) => set("general", { support_email: e.target.value })} />
            </Field>
            <Toggle
              checked={s.general.signup_enabled}
              onChange={(v) => set("general", { signup_enabled: v })}
              label="Cho phép đăng ký tài khoản mới"
            />
          </div>
        </Card>

        <Card title="Email (SMTP)">
          {r.dev_mode && (
            <div className="mb-4">
              <Alert tone="amber">Server đang chạy ở chế độ dev: khi chưa cấu hình SMTP, mã OTP được in ra log thay vì gửi email.</Alert>
            </div>
          )}
          <div className="grid gap-4 sm:grid-cols-3">
            <div className="sm:col-span-2">
              <Field label="Host">
                <Input placeholder="smtp.gmail.com" value={s.smtp.host} onChange={(e) => set("smtp", { host: e.target.value })} />
              </Field>
            </div>
            <Field label="Port">
              <Input type="number" value={s.smtp.port || ""} onChange={(e) => set("smtp", { port: Number(e.target.value) })} />
            </Field>
            <Field label="Username">
              <Input autoComplete="off" value={s.smtp.username} onChange={(e) => set("smtp", { username: e.target.value })} />
            </Field>
            <Field label="Password">
              <Input
                type="password"
                autoComplete="new-password"
                value={s.smtp.password}
                onChange={(e) => set("smtp", { password: e.target.value })}
              />
            </Field>
            <Field label="Bảo mật">
              <Select value={s.smtp.security} onChange={(e) => set("smtp", { security: e.target.value })}>
                <option value="starttls">STARTTLS (587)</option>
                <option value="tls">TLS (465)</option>
                <option value="none">Không mã hoá</option>
              </Select>
            </Field>
            <div className="sm:col-span-3">
              <Field label="Người gửi (From)">
                <Input placeholder="MyTermi <no-reply@example.com>" value={s.smtp.from} onChange={(e) => set("smtp", { from: e.target.value })} />
              </Field>
            </div>
          </div>
          <div className="mt-4 flex flex-wrap items-end gap-2 border-t border-line pt-4">
            <div className="min-w-48 flex-1">
              <Field label="Gửi email thử tới" hint="Lưu cấu hình trước khi gửi thử.">
                <Input type="email" value={testTo} onChange={(e) => setTestTo(e.target.value)} />
              </Field>
            </div>
            <Button variant="ghost" busy={busy === "test"} onClick={testEmail} className="mb-5">
              Gửi thử
            </Button>
          </div>
        </Card>

        <Card title="Đăng nhập bằng Google">
          <div className="space-y-4">
            <Toggle checked={s.google.enabled} onChange={(v) => set("google", { enabled: v })} label="Bật Google Sign-In" />
            <Field
              label="OAuth Client ID"
              hint="Mỗi dòng một Client ID (iOS, Android, Web) tạo trong Google Cloud Console. ID token phải có audience là một trong các ID này."
            >
              <ListInput
                value={s.google.client_ids}
                onChange={(v) => set("google", { client_ids: v })}
                placeholder="1234-abc.apps.googleusercontent.com"
              />
            </Field>
          </div>
        </Card>

        <Card title="Sign in with Apple">
          <div className="space-y-4">
            <Toggle checked={s.apple.enabled} onChange={(v) => set("apple", { enabled: v })} label="Bật Sign in with Apple" />
            <Field label="Audience" hint="Bundle ID của app iOS (VD: com.mytermi.app), thêm Services ID nếu đăng nhập Apple trên Android/web.">
              <ListInput value={s.apple.audiences} onChange={(v) => set("apple", { audiences: v })} placeholder="com.mytermi.app" />
            </Field>
          </div>
        </Card>
      </div>
    </>
  );
}
