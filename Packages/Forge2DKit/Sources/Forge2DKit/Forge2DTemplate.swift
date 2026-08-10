import Foundation

enum Forge2DTemplate {
    static let styles = #"""
    :root {
      color-scheme: dark;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      background: #090b0e;
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; overscroll-behavior: none; background: #090b0e; }
    #game-shell { position: relative; width: 100%; height: 100%; min-height: 100dvh; overflow: hidden; touch-action: none; }
    #game { width: 100%; height: 100%; display: block; background: #0c1118; }
    .status { position: absolute; top: max(14px, env(safe-area-inset-top)); left: 50%; transform: translateX(-50%); min-height: 44px; padding: 10px 14px; border-radius: 16px; background: rgba(10, 13, 18, .78); color: #f6f7f9; font-weight: 650; letter-spacing: .01em; backdrop-filter: blur(18px); }
    .pause { position: absolute; top: max(14px, env(safe-area-inset-top)); right: max(14px, env(safe-area-inset-right)); width: 48px; height: 48px; border-radius: 16px; border: 1px solid rgba(255,255,255,.18); background: rgba(10,13,18,.82); color: #fff; font: inherit; font-size: 20px; }
    .controls { position: absolute; bottom: max(18px, env(safe-area-inset-bottom)); display: flex; gap: 12px; }
    .controls-left { left: max(18px, env(safe-area-inset-left)); }
    .controls-right { right: max(18px, env(safe-area-inset-right)); }
    .controls button { width: 68px; height: 68px; border: 1px solid rgba(255,255,255,.2); border-radius: 22px; background: rgba(17,22,29,.76); color: white; font: inherit; font-size: 28px; font-weight: 700; backdrop-filter: blur(18px); touch-action: none; }
    .controls button:active, .controls button[data-active="true"] { transform: scale(.96); background: rgba(51,63,79,.92); }
    @media (prefers-reduced-transparency: reduce) { .status, .pause, .controls button { backdrop-filter: none; background: #171c24; } }
    @media (prefers-reduced-motion: reduce) { .controls button { transition: none; } }
    """#

    static func script(for blueprint: Forge2DBlueprint) -> String {
        #"""
        "use strict";

        const CONFIG = Object.freeze({
          viewportWidth: \#(blueprint.viewportWidth),
          viewportHeight: \#(blueprint.viewportHeight),
          worldWidth: \#(blueprint.worldWidth),
          worldHeight: \#(blueprint.worldHeight),
          gravity: \#(format(blueprint.gravity)),
          saveKey: "\#(escapeJavaScript(blueprint.persistenceKey))",
          step: 1 / 60,
          maxFrameDelta: 0.25,
          floorHeight: 120
        });

        const shell = document.getElementById("game-shell");
        const canvas = document.getElementById("game");
        const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });
        const status = document.getElementById("status");
        const pauseButton = document.getElementById("pause");
        const controls = {
          left: document.getElementById("left"),
          right: document.getElementById("right"),
          jump: document.getElementById("jump")
        };

        const input = {
          keyboardLeft: false,
          keyboardRight: false,
          touchLeft: false,
          touchRight: false,
          gamepadAxis: 0,
          semanticAxis: 0,
          jumpQueued: false,
          semanticJumpWasDown: false,
          gamepadJumpWasDown: false,
          gamepadPauseWasDown: false
        };
        const player = { x: 180, y: CONFIG.worldHeight - CONFIG.floorHeight - 72, width: 54, height: 72, vx: 0, vy: 0, grounded: true };
        const camera = { x: 0, y: 0 };
        const particles = [];
        const state = { paused: false, lastTime: 0, accumulator: 0, saveAccumulator: 0 };
        let audioContext = null;

        function bounded(value, min, max) { return Math.max(min, Math.min(max, value)); }

        function loadSave() {
          try {
            const raw = localStorage.getItem(CONFIG.saveKey);
            if (!raw) return;
            const saved = JSON.parse(raw);
            if (Number.isFinite(saved.x)) player.x = bounded(saved.x, 0, CONFIG.worldWidth - player.width);
            if (Number.isFinite(saved.y)) player.y = bounded(saved.y, 0, CONFIG.worldHeight - CONFIG.floorHeight - player.height);
          } catch { status.textContent = "Save reset"; }
        }

        function saveNow() {
          try {
            localStorage.setItem(CONFIG.saveKey, JSON.stringify({ version: 1, x: Math.round(player.x), y: Math.round(player.y) }));
          } catch { status.textContent = "Local save unavailable"; }
        }

        function ensureAudio() {
          if (audioContext) return audioContext;
          const AudioContextType = window.AudioContext || window.webkitAudioContext;
          if (!AudioContextType) return null;
          audioContext = new AudioContextType();
          return audioContext;
        }

        function jumpSound() {
          const audio = ensureAudio();
          if (!audio) return;
          const osc = audio.createOscillator();
          const gain = audio.createGain();
          osc.type = "triangle";
          osc.frequency.setValueAtTime(260, audio.currentTime);
          osc.frequency.exponentialRampToValueAtTime(520, audio.currentTime + 0.07);
          gain.gain.setValueAtTime(0.06, audio.currentTime);
          gain.gain.exponentialRampToValueAtTime(0.001, audio.currentTime + 0.09);
          osc.connect(gain).connect(audio.destination);
          osc.start();
          osc.stop(audio.currentTime + 0.1);
        }

        function spawnJumpParticles() {
          const baseY = player.y + player.height;
          for (let i = 0; i < 7; i += 1) {
            const direction = i % 2 === 0 ? -1 : 1;
            particles.push({
              x: player.x + player.width / 2,
              y: baseY,
              vx: direction * (35 + i * 11),
              vy: -70 - i * 9,
              life: 0.34 + i * 0.018
            });
          }
        }

        function queueJump() {
          input.jumpQueued = true;
          ensureAudio();
        }

        function bindHold(button, key) {
          const set = (value) => {
            input[key] = value;
            button.dataset.active = value ? "true" : "false";
            if (value) ensureAudio();
          };
          button.addEventListener("pointerdown", event => { event.preventDefault(); button.setPointerCapture(event.pointerId); set(true); });
          button.addEventListener("pointerup", event => { event.preventDefault(); set(false); });
          button.addEventListener("pointercancel", () => set(false));
          button.addEventListener("lostpointercapture", () => set(false));
        }

        bindHold(controls.left, "touchLeft");
        bindHold(controls.right, "touchRight");
        controls.jump.addEventListener("pointerdown", event => { event.preventDefault(); controls.jump.dataset.active = "true"; queueJump(); });
        controls.jump.addEventListener("pointerup", () => { controls.jump.dataset.active = "false"; });
        controls.jump.addEventListener("pointercancel", () => { controls.jump.dataset.active = "false"; });

        function semanticActionValue(event, expectedActionID) {
          const detail = event?.detail;
          if (!detail || detail.actionID !== expectedActionID || !Number.isFinite(detail.value)) return null;
          return bounded(detail.value, -1, 1);
        }

        shell.addEventListener("novaforge:action", event => {
          const value = semanticActionValue(event, "move-horizontal");
          if (value === null) return;
          input.semanticAxis = value;
        });

        controls.jump.addEventListener("novaforge:action", event => {
          const value = semanticActionValue(event, "jump");
          if (value === null) return;
          const jumpDown = value > 0.5;
          if (jumpDown && !input.semanticJumpWasDown) queueJump();
          input.semanticJumpWasDown = jumpDown;
        });

        function setPaused(paused) {
          state.paused = paused;
          pauseButton.setAttribute("aria-pressed", paused ? "true" : "false");
          pauseButton.setAttribute("aria-label", paused ? "Resume game" : "Pause game");
          pauseButton.textContent = paused ? "▶" : "Ⅱ";
          status.textContent = paused ? "Paused" : "Running";
          if (paused) saveNow();
        }

        pauseButton.addEventListener("click", () => setPaused(!state.paused));

        window.addEventListener("keydown", event => {
          if (["ArrowLeft", "KeyA"].includes(event.code)) input.keyboardLeft = true;
          if (["ArrowRight", "KeyD"].includes(event.code)) input.keyboardRight = true;
          if (["ArrowUp", "KeyW", "Space"].includes(event.code)) queueJump();
          if (event.code === "Escape" || event.code === "KeyP") setPaused(!state.paused);
          if (["ArrowLeft", "ArrowRight", "ArrowUp", "Space"].includes(event.code)) event.preventDefault();
        }, { passive: false });

        window.addEventListener("keyup", event => {
          if (["ArrowLeft", "KeyA"].includes(event.code)) input.keyboardLeft = false;
          if (["ArrowRight", "KeyD"].includes(event.code)) input.keyboardRight = false;
        });

        function pollGamepad() {
          const pad = navigator.getGamepads?.().find(Boolean);
          if (!pad) {
            input.gamepadAxis = 0;
            input.gamepadJumpWasDown = false;
            input.gamepadPauseWasDown = false;
            return;
          }
          const axis = Math.abs(pad.axes[0] || 0) > 0.18 ? pad.axes[0] : 0;
          input.gamepadAxis = axis;
          const jumpDown = Boolean(pad.buttons[0]?.pressed);
          if (jumpDown && !input.gamepadJumpWasDown) input.jumpQueued = true;
          input.gamepadJumpWasDown = jumpDown;
          const pauseDown = Boolean(pad.buttons[9]?.pressed);
          if (pauseDown && !input.gamepadPauseWasDown) setPaused(!state.paused);
          input.gamepadPauseWasDown = pauseDown;
        }

        function update(dt) {
          pollGamepad();
          const digitalHorizontal = (input.keyboardRight || input.touchRight ? 1 : 0) - (input.keyboardLeft || input.touchLeft ? 1 : 0);
          const horizontal = bounded(digitalHorizontal + input.gamepadAxis + input.semanticAxis, -1, 1);
          const targetVX = horizontal * 430;
          const response = player.grounded ? 16 : 7;
          player.vx += (targetVX - player.vx) * Math.min(1, response * dt);

          if (input.jumpQueued && player.grounded) {
            player.vy = -690;
            player.grounded = false;
            spawnJumpParticles();
            jumpSound();
          }
          input.jumpQueued = false;

          player.vy += CONFIG.gravity * dt;
          player.x += player.vx * dt;
          player.y += player.vy * dt;
          player.x = bounded(player.x, 0, CONFIG.worldWidth - player.width);

          const floorY = CONFIG.worldHeight - CONFIG.floorHeight - player.height;
          if (player.y >= floorY) {
            player.y = floorY;
            player.vy = 0;
            player.grounded = true;
          }

          for (let i = particles.length - 1; i >= 0; i -= 1) {
            const p = particles[i];
            p.life -= dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.vy += CONFIG.gravity * 0.18 * dt;
            if (p.life <= 0) particles.splice(i, 1);
          }

          const desiredX = player.x + player.width / 2 - CONFIG.viewportWidth / 2;
          camera.x += (bounded(desiredX, 0, CONFIG.worldWidth - CONFIG.viewportWidth) - camera.x) * Math.min(1, 8 * dt);
          camera.y = bounded(player.y + player.height / 2 - CONFIG.viewportHeight / 2, 0, CONFIG.worldHeight - CONFIG.viewportHeight);

          state.saveAccumulator += dt;
          if (state.saveAccumulator >= 2) { state.saveAccumulator = 0; saveNow(); }
        }

        function render() {
          const dpr = Math.min(window.devicePixelRatio || 1, 2);
          const cssWidth = Math.max(1, canvas.clientWidth);
          const cssHeight = Math.max(1, canvas.clientHeight);
          const pixelWidth = Math.round(cssWidth * dpr);
          const pixelHeight = Math.round(cssHeight * dpr);
          if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
            canvas.width = pixelWidth;
            canvas.height = pixelHeight;
          }

          ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
          ctx.fillStyle = "#0c1118";
          ctx.fillRect(0, 0, cssWidth, cssHeight);

          const scale = Math.min(cssWidth / CONFIG.viewportWidth, cssHeight / CONFIG.viewportHeight);
          const offsetX = (cssWidth - CONFIG.viewportWidth * scale) / 2;
          const offsetY = (cssHeight - CONFIG.viewportHeight * scale) / 2;
          ctx.translate(offsetX, offsetY);
          ctx.scale(scale, scale);
          ctx.translate(-camera.x, -camera.y);

          ctx.fillStyle = "#101a25";
          ctx.fillRect(0, 0, CONFIG.worldWidth, CONFIG.worldHeight);
          for (let x = 0; x < CONFIG.worldWidth; x += 160) {
            ctx.fillStyle = x % 320 === 0 ? "#132536" : "#10202e";
            ctx.fillRect(x, 0, 80, CONFIG.worldHeight - CONFIG.floorHeight);
          }
          ctx.fillStyle = "#293746";
          ctx.fillRect(0, CONFIG.worldHeight - CONFIG.floorHeight, CONFIG.worldWidth, CONFIG.floorHeight);

          for (const p of particles) {
            ctx.globalAlpha = bounded(p.life / 0.45, 0, 1);
            ctx.fillStyle = "#b8e8ff";
            ctx.fillRect(p.x - 4, p.y - 4, 8, 8);
          }
          ctx.globalAlpha = 1;
          ctx.fillStyle = "#f4f7fb";
          ctx.fillRect(player.x, player.y, player.width, player.height);
          ctx.fillStyle = "#78d5ff";
          ctx.fillRect(player.x + 8, player.y + 12, player.width - 16, 10);
        }

        function frame(timestamp) {
          const seconds = timestamp / 1000;
          if (!state.lastTime) state.lastTime = seconds;
          const frameDelta = Math.min(CONFIG.maxFrameDelta, Math.max(0, seconds - state.lastTime));
          state.lastTime = seconds;

          if (!state.paused) {
            state.accumulator += frameDelta;
            while (state.accumulator >= CONFIG.step) {
              update(CONFIG.step);
              state.accumulator -= CONFIG.step;
            }
          }
          render();
          requestAnimationFrame(frame);
        }

        document.addEventListener("visibilitychange", () => {
          if (document.hidden) { saveNow(); state.lastTime = 0; }
        });
        window.addEventListener("pagehide", saveNow);

        loadSave();
        status.textContent = "Running";
        requestAnimationFrame(frame);
        """#
    }

    private static func escapeJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
