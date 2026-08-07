import Foundation

extension Forge3DTemplate {
    static let scriptCoreA = #"""
const canvas = document.getElementById("scene");
const status = document.getElementById("status");
const pauseButton = document.getElementById("pause");
const joystick = document.getElementById("joystick");
const joystickKnob = document.getElementById("joystick-knob");
const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)");

const gl = canvas.getContext("webgl", { alpha: false, antialias: true, depth: true });
if (!gl) {
  status.textContent = "WebGL is unavailable on this device";
  pauseButton.disabled = true;
  joystick.hidden = true;
  throw new Error("Forge3DKit requires WebGL");
}

const vertexSource = `
  attribute vec3 aPosition;
  uniform mat4 uMVP;
  void main() { gl_Position = uMVP * vec4(aPosition, 1.0); }
`;
const fragmentSource = `
  precision mediump float;
  uniform vec4 uColor;
  void main() { gl_FragColor = uColor; }
`;

function compileShader(type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const message = gl.getShaderInfoLog(shader) || "Unknown shader error";
    gl.deleteShader(shader);
    throw new Error(message);
  }
  return shader;
}

function createProgram() {
  const program = gl.createProgram();
  const vertex = compileShader(gl.VERTEX_SHADER, vertexSource);
  const fragment = compileShader(gl.FRAGMENT_SHADER, fragmentSource);
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  gl.deleteShader(vertex);
  gl.deleteShader(fragment);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const message = gl.getProgramInfoLog(program) || "Unknown program link error";
    gl.deleteProgram(program);
    throw new Error(message);
  }
  return program;
}

const program = createProgram();
const aPosition = gl.getAttribLocation(program, "aPosition");
const uMVP = gl.getUniformLocation(program, "uMVP");
const uColor = gl.getUniformLocation(program, "uColor");

const cubeVertices = new Float32Array([
  -0.5,-0.5, 0.5,  0.5,-0.5, 0.5,  0.5, 0.5, 0.5, -0.5,-0.5, 0.5,  0.5, 0.5, 0.5, -0.5, 0.5, 0.5,
   0.5,-0.5,-0.5, -0.5,-0.5,-0.5, -0.5, 0.5,-0.5, 0.5,-0.5,-0.5, -0.5, 0.5,-0.5, 0.5, 0.5,-0.5,
  -0.5,-0.5,-0.5, -0.5,-0.5, 0.5, -0.5, 0.5, 0.5, -0.5,-0.5,-0.5, -0.5, 0.5, 0.5, -0.5, 0.5,-0.5,
   0.5,-0.5, 0.5,  0.5,-0.5,-0.5, 0.5, 0.5,-0.5, 0.5,-0.5, 0.5, 0.5, 0.5,-0.5, 0.5, 0.5, 0.5,
  -0.5, 0.5, 0.5,  0.5, 0.5, 0.5, 0.5, 0.5,-0.5, -0.5, 0.5, 0.5, 0.5, 0.5,-0.5, -0.5, 0.5,-0.5,
  -0.5,-0.5,-0.5, 0.5,-0.5,-0.5, 0.5,-0.5, 0.5, -0.5,-0.5,-0.5, 0.5,-0.5, 0.5, -0.5,-0.5, 0.5
]);
const groundVertices = new Float32Array([
  -1,0,-1, 1,0,1, 1,0,-1,
  -1,0,-1, -1,0,1, 1,0,1
]);

function makeBuffer(data) {
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
  return buffer;
}
const cubeBuffer = makeBuffer(cubeVertices);
const groundBuffer = makeBuffer(groundVertices);

function identity() {
  return new Float32Array([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]);
}
function multiply(a, b) {
  const out = new Float32Array(16);
  for (let c = 0; c < 4; c += 1) {
    for (let r = 0; r < 4; r += 1) {
      out[c * 4 + r] =
        a[r] * b[c * 4] +
        a[4 + r] * b[c * 4 + 1] +
        a[8 + r] * b[c * 4 + 2] +
        a[12 + r] * b[c * 4 + 3];
    }
  }
  return out;
}
function translation(x, y, z) {
  const out = identity(); out[12] = x; out[13] = y; out[14] = z; return out;
}
function rotationY(angle) {
  const c = Math.cos(angle), s = Math.sin(angle);
  return new Float32Array([c,0,-s,0, 0,1,0,0, s,0,c,0, 0,0,0,1]);
}
function scaling(x, y, z) {
  return new Float32Array([x,0,0,0, 0,y,0,0, 0,0,z,0, 0,0,0,1]);
}
function perspective(fovRadians, aspect, near, far) {
  const f = 1 / Math.tan(fovRadians / 2);
  const nf = 1 / (near - far);
  return new Float32Array([
    f / aspect,0,0,0,
    0,f,0,0,
    0,0,(far + near) * nf,-1,
    0,0,(2 * far * near) * nf,0
  ]);
}
function normalize3(v) {
  const length = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / length, v[1] / length, v[2] / length];
}
function cross(a, b) {
  return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
}
function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
function lookAt(eye, center, up) {
  const z = normalize3([eye[0]-center[0], eye[1]-center[1], eye[2]-center[2]]);
  const x = normalize3(cross(up, z));
  const y = cross(z, x);
  return new Float32Array([
    x[0],y[0],z[0],0,
    x[1],y[1],z[1],0,
    x[2],y[2],z[2],0,
    -dot(x, eye),-dot(y, eye),-dot(z, eye),1
  ]);
}
function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
function approach(value, target, maxDelta) {
  if (value < target) return Math.min(target, value + maxDelta);
  return Math.max(target, value - maxDelta);
}

const input = { keyThrottle: 0, keySteer: 0, touchThrottle: 0, touchSteer: 0, accessibleThrottle: 0, accessibleSteer: 0, padThrottle: 0, padSteer: 0, padPauseWasDown: false };
const vehicle = { x: 0, z: 0, yaw: 0, speed: 0 };
const camera = { x: 0, y: 5.2, z: -8.5 };
const state = { paused: false, lastTime: 0, accumulator: 0, saveAccumulator: 0, contextLost: false };
let activeJoystickPointer = null;

function loadSave() {
  try {
    const raw = localStorage.getItem(CONFIG.saveKey);
    if (!raw) return;
    const saved = JSON.parse(raw);
    if (Number.isFinite(saved.x)) vehicle.x = clamp(saved.x, -CONFIG.worldHalfExtent, CONFIG.worldHalfExtent);
    if (Number.isFinite(saved.z)) vehicle.z = clamp(saved.z, -CONFIG.worldHalfExtent, CONFIG.worldHalfExtent);
    if (Number.isFinite(saved.yaw)) vehicle.yaw = saved.yaw;
  } catch { status.textContent = "3D save reset"; }
}
function saveNow() {
  try {
    localStorage.setItem(CONFIG.saveKey, JSON.stringify({ version: 1, x: vehicle.x, z: vehicle.z, yaw: vehicle.yaw }));
  } catch { status.textContent = "Local save unavailable"; }
}

function setPaused(paused) {
  state.paused = paused;
  pauseButton.setAttribute("aria-pressed", paused ? "true" : "false");
  pauseButton.setAttribute("aria-label", paused ? "Resume scene" : "Pause scene");
  pauseButton.textContent = paused ? "▶" : "Ⅱ";
  if (!state.contextLost) status.textContent = paused ? "Paused" : "Running 3D scene";
  if (paused) saveNow();
}
pauseButton.addEventListener("click", () => setPaused(!state.paused));
"""#
}
