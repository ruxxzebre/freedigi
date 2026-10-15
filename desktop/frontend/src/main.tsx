import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Gamepad2,
  SlidersHorizontal,
  Waypoints,
  Lightbulb,
  Download,
  ScrollText,
  Info,
  RefreshCw,
  ArrowUpRight,
  Copy,
  Play,
  Square,
  ShieldCheck,
  ChevronRight,
  Save,
  Activity,
  RotateCcw,
  Zap,
  ArrowRight,
} from "lucide-react";
import { api, initial, names, native, type State, type Input } from "./api";
import "./style.css";
const pages = [
  ["Overview", Gamepad2],
  ["Button mapping", Waypoints],
  ["Lighting", Lightbulb],
  ["Controller settings", SlidersHorizontal],
  ["Firmware", Download],
  ["Diagnostics", ScrollText],
  ["About", Info],
] as const;
const subtitles: Record<string, string> = {
  Overview: "Your controller. Your rules.",
  "Button mapping": "Make every button feel right.",
  Lighting: "A little color. A lot of you.",
  "Controller settings": "Hardware settings, with a clear readback.",
  Firmware: "Know what’s running inside your controller.",
  Diagnostics: "Every operation leaves a trail.",
  About: "Open controls. Built on good work.",
};
function Toggle({
  checked,
  onChange,
  label,
  disabled = false,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  disabled?: boolean;
}) {
  return (
    <button
      className={"toggle " + (checked ? "on" : "")}
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
    >
      <span />
    </button>
  );
}
function App() {
  const [page, setPage] = useState("Overview"),
    [state, setState] = useState<State>(initial),
    [input, setInput] = useState<Input | null>(null),
    [busy, setBusy] = useState(""),
    [notice, setNotice] = useState<{ text: string; error?: boolean } | null>(
      null,
    );
  const [staged, setStaged] = useState<Record<string, number>>({}),
    [color, setColor] = useState("#4ba5ff"),
    [brightness, setBrightness] = useState(70),
    [off, setOff] = useState(false);
  useEffect(() => {
    let active = true;
    const update = () =>
      api
        .Status()
        .then((s) => {
          if (active) {
            setState(s);
            setInput(s.input);
          }
        })
        .catch(() => {});
    api
      .Refresh()
      .then((s) => {
        if (active) setState(s);
      })
      .catch((e) => setNotice({ text: String(e), error: true }));
    const timer = setInterval(update, 1200);
    const unsub = window.runtime?.EventsOn("controller", (e) => {
      if (e.event === "input" && e.state) setInput(e.state);
      if (e.event === "monitor" && e.running === false) setInput(null);
    });
    return () => {
      active = false;
      clearInterval(timer);
      unsub?.();
    };
  }, []);
  async function task(label: string, fn: () => Promise<unknown>) {
    if (busy) return;
    setBusy(label);
    setNotice(null);
    try {
      const result = await fn();
      setState(await api.Status());
      return result;
    } catch (e) {
      setNotice({ text: String(e), error: true });
      setState(await api.Status());
      return null;
    } finally {
      setBusy("");
    }
  }
  async function run(action: string, params: Record<string, unknown> = {}) {
    const result = await task(action, () => api.Perform(action, params));
    if (result) {
      const r = result as Record<string, unknown>;
      setNotice({
        text: r.preview
          ? String(r.message)
          : "Done. The controller response was read successfully.",
      });
      if (action === "profileRead" || (action === "profileApply" && !r.preview))
        setStaged({});
      if (action === "lightingRead") {
        setColor(String(r.color));
        setBrightness(Number(r.brightness));
        setOff(r.mode === 0);
      }
    }
    return result;
  }
  const connected = !!state.path,
    locked = !!busy || !!state.busy,
    device = state.devices.find((d) => d.path === state.path),
    data = state.data;
  const changes = Object.entries(staged).filter(
    ([k, v]) => data.mappings?.[k] !== v,
  ).length;
  const actionLabel = state.dryRun ? "Preview changes" : "Apply changes";
  const topAction = (
    <button
      onClick={() => task("Refresh devices", () => api.Refresh())}
      disabled={locked}
    >
      <RefreshCw
        size={15}
        className={busy === "Refresh devices" ? "spin" : ""}
      />
      Refresh devices
    </button>
  );
  const readButton = (action: string, text = "Read from controller") => (
    <button onClick={() => run(action)} disabled={!connected || locked}>
      <RefreshCw size={15} />
      {text}
    </button>
  );
  const statusText = state.busy
    ? "Monitoring paused for settings"
    : state.monitoring
      ? "Receiving inputs"
      : connected
        ? "Ready to read"
        : "No controller selected";
  return (
    <div className="shell">
      <aside className="sidebar">
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            setPage("Overview");
          }}
        >
          <span className="brand-mark">
            <Gamepad2 size={26} />
          </span>
          <span>
            FreeDigi<small>MAKE IT YOURS</small>
          </span>
        </a>
        <div className="workspace-label">WORKSPACE</div>
        <nav aria-label="Main navigation">
          {pages.map(([name, Icon]) => (
            <button
              key={name}
              className={page === name ? "active" : ""}
              onClick={() => setPage(name)}
            >
              <Icon size={19} />
              <span>{name}</span>
              {page === name && <span className="nav-dot" />}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="built-on">
            <span className="mini-mark">C</span>
            <div>
              Built on ControlLab<small>Open source. MIT licensed.</small>
            </div>
          </div>
          <div className="build-label">
            FreeDigi <span>0.1.0 · preview</span>
          </div>
        </div>
      </aside>
      <div className="workspace">
        <header className="toolbar">
          <span className="breadcrumb">
            Workspace <ChevronRight size={13} /> <strong>{page}</strong>
          </span>
          <div className="dry-run">
            <ShieldCheck size={16} />
            <span>
              Dry run{" "}
              <small>
                {state.dryRun ? "Writes are previewed" : "Live writes enabled"}
              </small>
            </span>
            <Toggle
              checked={state.dryRun}
              onChange={(v) => task("Change dry run", () => api.SetDryRun(v))}
              label="Dry run"
              disabled={locked}
            />
          </div>
        </header>
        <main>
          <div className="page-heading">
            <div>
              <div className="eyebrow">YOUR CONTROLLER WORKSPACE</div>
              <h1>{page}</h1>
              <p>{subtitles[page]}</p>
            </div>
            {topAction}
          </div>
          {native && state.platformSupported === false && (
            <div className="banner">
              <Info size={17} />
              {state.platformMessage}
            </div>
          )}
          {!native && (
            <div className="banner">
              <Info size={17} />
              Browser preview — hardware is unavailable. Launch FreeDigi to
              connect a controller.
            </div>
          )}
          {notice && (
            <div
              role={notice.error ? "alert" : "status"}
              className={"banner " + (notice.error ? "error" : "success")}
            >
              <Info size={17} />
              <span>{notice.text}</span>
              <button
                className="dismiss"
                aria-label="Dismiss notification"
                onClick={() => setNotice(null)}
              >
                ×
              </button>
            </div>
          )}
          <div className="device-strip">
            <span
              className={"status-orb " + (state.monitoring ? "live" : "")}
            />
            <div>
              <strong>{statusText}</strong>
              <small>
                {device?.name ??
                  "Connect a Vader 5 Pro using its receiver or a USB cable"}
              </small>
            </div>
            <select
              aria-label="Controller"
              value={state.path}
              disabled={locked}
              onChange={(e) => {
                setStaged({});
                task("Select controller", () => api.Select(e.target.value));
              }}
            >
              <option value="">Select controller</option>
              {state.devices.map((d) => (
                <option key={d.path} value={d.path} disabled={!d.accessible}>
                  {d.name} · {d.path}
                  {!d.accessible ? " · permission needed" : ""}
                </option>
              ))}
            </select>
          </div>
          {state.devices.some((d) => !d.accessible) && (
            <div className="banner">
              Device found, but access is blocked. Install the supplied
              70-freedigi.rules as described in the README, then reconnect it.
            </div>
          )}
          {page === "Overview" && (
            <>
              <div className="overview-grid">
                <section className="card hero">
                  <div className="card-heading">
                    <div>
                      <span className="eyebrow">FLYDIGI</span>
                      <h2>Vader 5 Pro</h2>
                    </div>
                    <span className="badge">USB / RECEIVER</span>
                  </div>
                  <div className="controller-art">
                    <div className="halo" />
                    <img
                      src="/controller.png"
                      alt="Flydigi Vader 5 Pro controller"
                    />
                    <span className="art-caption">
                      CONFIGURE · CUSTOMIZE · PLAY
                    </span>
                  </div>
                  <div className="hero-footer">
                    <span>
                      <span
                        className={
                          "status-orb " + (state.monitoring ? "live" : "")
                        }
                      />{" "}
                      {state.monitoring
                        ? "Input stream active"
                        : "Input stream stopped"}
                    </span>
                    <button
                      className="primary"
                      disabled={!connected || locked}
                      onClick={() =>
                        task("Input monitor", () =>
                          api.Monitor(!state.monitorWanted),
                        )
                      }
                    >
                      {state.monitorWanted ? (
                        <Square size={15} />
                      ) : (
                        <Play size={15} />
                      )}{" "}
                      {state.monitorWanted
                        ? "Stop monitoring"
                        : "Start monitoring"}
                    </button>
                  </div>
                </section>
                <div className="right-stack">
                  <section className="card">
                    <div className="card-heading">
                      <h3>
                        <Activity size={18} />
                        Live inputs
                      </h3>
                      <span
                        className={"badge " + (state.monitoring ? "green" : "")}
                      >
                        {state.monitoring ? "LIVE" : "IDLE"}
                      </span>
                    </div>
                    <p className="muted">
                      Physical buttons reported by the configuration stream.
                    </p>
                    <div className="input-grid">
                      {names.map((name, id) => (
                        <span
                          key={id}
                          className={
                            input?.buttons.includes(id) ? "pressed" : ""
                          }
                        >
                          {name.replace("D-pad ", "").toUpperCase()}
                        </span>
                      ))}
                    </div>
                    <div className="stick-row">
                      {(["left", "right"] as const).map((side) => (
                        <div className="stick-wrap" key={side}>
                          <div className="stick">
                            <i
                              style={{
                                transform: `translate(${(input?.[`${side}X`] ?? 0) * 24}px,${-(input?.[`${side}Y`] ?? 0) * 24}px)`,
                              }}
                            />
                          </div>
                          <span>
                            {side === "left" ? "LEFT" : "RIGHT"} STICK
                          </span>
                        </div>
                      ))}
                    </div>
                    {(["left", "right"] as const).map((side) => (
                      <div className="trigger" key={side}>
                        <span>{side === "left" ? "LT" : "RT"}</span>
                        <div>
                          <i
                            style={{
                              width: `${(input?.[`${side}Trigger`] ?? 0) * 100}%`,
                            }}
                          />
                        </div>
                        <small>
                          {Math.round((input?.[`${side}Trigger`] ?? 0) * 100)}%
                        </small>
                      </div>
                    ))}
                  </section>
                </div>
              </div>
              <div className="quick-grid">
                {[
                  [
                    Waypoints,
                    "Your button layout",
                    "Remap face, shoulder and back buttons.",
                    "Button mapping",
                  ],
                  [
                    Lightbulb,
                    "Set the mood",
                    "Solid colors and brightness, your way.",
                    "Lighting",
                  ],
                  [
                    Zap,
                    "Turbo & calibration",
                    "Read and adjust hardware features.",
                    "Controller settings",
                  ],
                ].map(([Icon, title, desc, dest]) => {
                  const I = Icon as typeof Gamepad2;
                  return (
                    <button
                      className="quick-card"
                      key={String(title)}
                      onClick={() => setPage(String(dest))}
                    >
                      <I size={22} />
                      <strong>{String(title)}</strong>
                      <span>{String(desc)}</span>
                      <ArrowUpRight size={17} />
                    </button>
                  );
                })}
              </div>
              <p className="footnote">
                <Info size={14} />
                Input monitoring shows controller data. It does not create a
                virtual gamepad or guarantee game compatibility.
              </p>
            </>
          )}
          {page === "Button mapping" && (
            <>
              <section className="card">
                <div className="card-heading">
                  <div>
                    <h2>
                      {data.snapshot
                        ? data.title || "Active profile"
                        : "Your button layout"}
                    </h2>
                    <p className="muted">
                      {data.snapshot
                        ? `Profile ${data.slot} · ${changes} staged change${changes === 1 ? "" : "s"}`
                        : "Read the active profile to load the controller’s mappings."}
                    </p>
                  </div>
                  {readButton("profileRead", "Read active profile")}
                </div>
                {!data.snapshot ? (
                  <Empty
                    icon={Waypoints}
                    title="Start with what’s on your controller"
                    text="Read the profile, choose a source button, then choose what it should do. Existing advanced mappings are preserved until you change that row."
                  />
                ) : (
                  <>
                    <div className="mapping-header">
                      <span>PHYSICAL BUTTON</span>
                      <span>MAP TO</span>
                    </div>
                    <div className="mapping-list">
                      {names.map((name, id) => {
                        const current = data.mappings?.[id],
                          value = staged[id] ?? current;
                        return (
                          <div
                            className={
                              "mapping-row " +
                              (staged[id] !== undefined &&
                              staged[id] !== current
                                ? "changed"
                                : "")
                            }
                            key={id}
                          >
                            <span
                              className={
                                "keycap " +
                                (input?.buttons.includes(id) ? "pressed" : "")
                              }
                            >
                              {name.replace("D-pad ", "")}
                            </span>
                            <div>
                              <strong>{name}</strong>
                              <small>
                                {id >= 18
                                  ? "Back button"
                                  : id >= 16
                                    ? "Extra face button"
                                    : "Standard control"}
                              </small>
                            </div>
                            <ArrowRight size={16} />
                            <select
                              aria-label={`Map ${name} to`}
                              value={value ?? "custom"}
                              disabled={locked}
                              onChange={(e) =>
                                setStaged((v) => ({
                                  ...v,
                                  [id]: Number(e.target.value),
                                }))
                              }
                            >
                              {value == null && (
                                <option value="custom">
                                  Custom mapping (preserved)
                                </option>
                              )}
                              {names.map((target, n) => (
                                <option key={n} value={n}>
                                  {target}
                                  {n === id ? " (default)" : ""}
                                </option>
                              ))}
                            </select>
                          </div>
                        );
                      })}
                    </div>
                    <div className="action-bar">
                      <button
                        disabled={locked || !changes}
                        onClick={() => setStaged({})}
                      >
                        <RotateCcw size={15} />
                        Discard edits
                      </button>
                      <span />
                      {state.dryRun && <small>No device writes</small>}
                      <button
                        disabled={!connected || locked || !changes}
                        onClick={() =>
                          run("profileApply", {
                            mappings: staged,
                            persist: false,
                          })
                        }
                      >
                        {state.dryRun
                          ? "Preview temporary apply"
                          : "Apply until restart"}
                      </button>
                      <button
                        className="primary"
                        disabled={!connected || locked || !changes}
                        onClick={() =>
                          run("profileApply", {
                            mappings: staged,
                            persist: true,
                          })
                        }
                      >
                        <Save size={15} />
                        {state.dryRun ? "Preview save" : "Save to controller"}
                      </button>
                    </div>
                  </>
                )}
              </section>
              <p className="footnote">
                A backup is saved before each live profile write. Apply verifies
                the profile first and reads it back afterward. Custom
                combinations, macros and rapid fire are preserved, but their
                editors are not included yet.
              </p>
            </>
          )}
          {page === "Lighting" && (
            <section className="card">
              <div className="card-heading">
                <div>
                  <h2>Make it glow</h2>
                  <p className="muted">
                    Solid color and brightness for the controller LEDs.
                  </p>
                </div>
                {readButton("lightingRead", "Read lighting")}
              </div>
              {!data.lighting ? (
                <Empty
                  icon={Lightbulb}
                  title="Read your lighting first"
                  text="FreeDigi keeps the controller’s LED layout and configuration format when building your changes."
                />
              ) : (
                <div className="lighting-layout">
                  <div
                    className="color-preview"
                    style={{ "--glow": color } as React.CSSProperties}
                  >
                    <img
                      src="/controller.png"
                      alt="Controller lighting preview"
                    />
                    <span>Color preview · not a live camera</span>
                  </div>
                  <div className="lighting-controls">
                    <label>
                      Solid color
                      <div className="color-picker">
                        <input
                          aria-label="LED color"
                          type="color"
                          value={color}
                          onChange={(e) => setColor(e.target.value)}
                        />
                        <code>{color.toUpperCase()}</code>
                      </div>
                    </label>
                    <label>
                      Brightness <strong>{brightness}%</strong>
                      <input
                        aria-label="Brightness"
                        type="range"
                        min="0"
                        max="100"
                        value={brightness}
                        onChange={(e) => setBrightness(Number(e.target.value))}
                      />
                    </label>
                    <div className="setting-switch">
                      <span>Turn LEDs off</span>
                      <Toggle
                        checked={off}
                        onChange={setOff}
                        label="Turn LEDs off"
                      />
                    </div>
                    <button
                      className="primary"
                      disabled={!connected || locked}
                      onClick={() =>
                        run("lightingApply", { color, brightness, off })
                      }
                    >
                      {actionLabel}
                    </button>
                    <p className="muted">
                      Live changes are checked against a fresh read and verified
                      afterward.
                    </p>
                  </div>
                </div>
              )}
            </section>
          )}
          {page === "Controller settings" && (
            <div className="settings-grid">
              {(["turbo", "calibration"] as const).map((key) => (
                <section className="card" key={key}>
                  <div className="card-heading">
                    <span className="feature-icon">
                      {key === "turbo" ? <Zap /> : <SlidersHorizontal />}
                    </span>
                    {readButton(`${key}Read`, "Read setting")}
                  </div>
                  <h2>
                    {key === "turbo"
                      ? "Physical Turbo button"
                      : "Automatic stick calibration"}
                  </h2>
                  <p className="setting-description">
                    {key === "turbo"
                      ? "Enable the controller’s Turbo-button features, including its hardware mapping workflow. This switch does not assign rapid fire to a button."
                      : "Enable the firmware’s automatic stick-calibration feature. The controller handles the adjustment internally; this does not launch a manual calibration wizard."}
                  </p>
                  <div className="setting-value">
                    <span>On controller</span>
                    <strong>
                      {!data[key]
                        ? "Not read"
                        : !data[key]?.supported
                          ? "Not supported"
                          : data[key]?.enabled
                            ? "Enabled"
                            : "Disabled"}
                    </strong>
                  </div>
                  <button
                    className="primary"
                    disabled={!connected || locked || !data[key]?.supported}
                    onClick={() =>
                      run(`${key}Apply`, { enabled: !data[key]?.enabled })
                    }
                  >
                    {state.dryRun ? "Preview: " : ""}
                    {data[key]?.enabled ? "Disable" : "Enable"}
                  </button>
                </section>
              ))}
            </div>
          )}
          {page === "Firmware" && (
            <section className="card">
              <div className="card-heading">
                <div>
                  <h2>Installed firmware</h2>
                  <p className="muted">
                    Versions reported by the connected controller and receiver.
                  </p>
                </div>
                {readButton("firmwareRead", "Read versions")}
              </div>
              <div className="version-list">
                {[
                  ["main", "Main controller"],
                  ["rf", "Controller radio"],
                  ["si", "Bluetooth / SI"],
                  ["dongle", "USB receiver"],
                ].map(([key, label]) => (
                  <div key={key}>
                    <span>
                      <span className="feature-icon small">
                        <Download size={16} />
                      </span>
                      {label}
                    </span>
                    <code>{data.versions?.[key] ?? "Not reported"}</code>
                  </div>
                ))}
              </div>
              <div className="banner">
                <Info size={17} />
                <span>
                  <strong>
                    Firmware installation is not available in this preview.
                  </strong>{" "}
                  The update and recovery paths still need validation for the
                  new desktop app. Reading versions does not flash firmware.
                </span>
              </div>
            </section>
          )}
          {page === "Diagnostics" && (
            <section className="card">
              <div className="card-heading">
                <div>
                  <h2>Operation log</h2>
                  <p className="muted">
                    Last 200 events · reads, writes, dry runs and transport
                    errors.
                  </p>
                </div>
                <div className="button-group">
                  <button
                    disabled={!native}
                    onClick={() =>
                      task("Copy report", async () => {
                        await api.CopyReport();
                        setNotice({ text: "Diagnostic report copied." });
                      })
                    }
                  >
                    <Copy size={15} />
                    Copy report
                  </button>
                  <button
                    disabled={!native}
                    onClick={() =>
                      task("Export report", () => api.ExportReport())
                    }
                  >
                    <Download size={15} />
                    Export
                  </button>
                </div>
              </div>
              <div className="diagnostic-facts">
                <div>
                  <small>BUILD</small>
                  <code>{state.build}</code>
                </div>
                <div>
                  <small>WRITE MODE</small>
                  <strong>{state.dryRun ? "Dry run" : "Live"}</strong>
                </div>
                <div>
                  <small>INPUT STREAM</small>
                  <strong>
                    {state.busy
                      ? "Paused for settings"
                      : state.monitoring
                        ? "Running"
                        : "Stopped"}
                  </strong>
                </div>
              </div>
              {state.error && <div className="banner error">{state.error}</div>}
              <div className="logs">
                {!state.logs.length ? (
                  <Empty
                    icon={ScrollText}
                    title="A clean slate"
                    text="Controller operations appear here. Copy a report when something needs a closer look."
                  />
                ) : (
                  [...state.logs].reverse().map((event, i) => (
                    <div className="log" key={i}>
                      <time>{new Date(event.time).toLocaleTimeString()}</time>
                      <span className="badge">{event.mode}</span>
                      <div>
                        <strong>{event.action}</strong>
                        <pre>{event.message}</pre>
                      </div>
                    </div>
                  ))
                )}
              </div>
            </section>
          )}
          {page === "About" && (
            <section className="card about">
              <div className="about-mark">
                <Gamepad2 size={46} />
              </div>
              <span className="eyebrow">OPEN SOURCE CONTROLLER TOOLS</span>
              <h2>FreeDigi</h2>
              <p>
                A desktop home for your Flydigi controller.
                <br />
                Built with Wails, React, Go and Swift for Linux and macOS.
              </p>
              <div className="credit">
                <h3>Built on ControlLab</h3>
                <p>
                  FreeDigi is based on the original{" "}
                  <strong>ControlLab Swift controller app by dracinn</strong>.
                  Its controller protocol code powers profile editing, Turbo,
                  calibration and lighting here.
                </p>
                <a
                  href="https://github.com/dracinn/ControlLab"
                  target="_blank"
                  rel="noreferrer"
                >
                  Original ControlLab project <ArrowUpRight size={15} />
                </a>
                <p className="muted">
                  ControlLab © 2026 dracinn · MIT License.
                  <br />
                  The original copyright notice and license are included with
                  FreeDigi.
                </p>
              </div>
              <a
                href="https://github.com/ruxxzebre/freedigi"
                target="_blank"
                rel="noreferrer"
              >
                FreeDigi on GitHub <ArrowUpRight size={15} />
              </a>
              <p className="footnote">
                Independent community software. Not affiliated with Flydigi.
                <br />
                This preview supports Vader 5 Pro configuration over USB and
                receiver. Bluetooth configuration, virtual gamepad output and
                firmware flashing are not included.
              </p>
            </section>
          )}
          <footer>
            <span>
              <span className="tiny-dot" />
              Local app · Direct controller access
            </span>
            <span>FreeDigi · Built on ControlLab</span>
          </footer>
        </main>
        {locked && (
          <div className="progress-toast" role="status">
            <RefreshCw className="spin" size={16} />
            {busy || state.busy}
            <span>Working…</span>
          </div>
        )}
      </div>
    </div>
  );
}
function Empty({
  icon: Icon,
  title,
  text,
}: {
  icon: typeof Gamepad2;
  title: string;
  text: string;
}) {
  return (
    <div className="empty">
      <span>
        <Icon size={29} />
      </span>
      <h3>{title}</h3>
      <p>{text}</p>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
