import Foundation

extension Forge3DTemplate {
    static let scriptCoreB = #"""
function updateKeyboard() {
  input.keyThrottle = (keys.has("KeyW") || keys.has("ArrowUp") ? 1 : 0) - (keys.has("KeyS") || keys.has("ArrowDown") ? 1 : 0);
  input.keySteer = (keys.has("KeyD") || keys.has("ArrowRight") ? 1 : 0) - (keys.has("KeyA") || keys.has("ArrowLeft") ? 1 : 0);
}
const keys = new Set();
window.addEventListener("keydown", event => {
  if (["KeyW","KeyA","KeyS","KeyD","ArrowUp","ArrowDown","ArrowLeft","ArrowRight"].includes(event.code)) {
    keys.add(event.code); updateKeyboard(); event.preventDefault();
  }
  if ((event.code === "Escape" || event.code === "KeyP") && !event.repeat) setPaused(!state.paused);
}, { passive: false });
window.addEventListener("keyup", event => { keys.delete(event.code); updateKeyboard(); });
window.addEventListener("blur", () => { keys.clear(); updateKeyboard(); });

function resetJoystick() {
  input.touchSteer = 0; input.touchThrottle = 0; activeJoystickPointer = null;
  joystickKnob.style.transform = "translate3d(0px, 0px, 0)";
}
function updateJoystick(event) {
  const rect = joystick.getBoundingClientRect();
  const radius = Math.max(1, Math.min(rect.width, rect.height) * 0.5);
  let x = (event.clientX - (rect.left + rect.width / 2)) / radius;
  let y = (event.clientY - (rect.top + rect.height / 2)) / radius;
  const magnitude = Math.hypot(x, y);
  if (magnitude > 1) { x /= magnitude; y /= magnitude; }
  input.touchSteer = clamp(x, -1, 1);
  input.touchThrottle = clamp(-y, -1, 1);
  joystickKnob.style.transform = `translate3d(${x * radius * 0.48}px, ${y * radius * 0.48}px, 0)`;
}
joystick.addEventListener("pointerdown", event => {
  event.preventDefault(); activeJoystickPointer = event.pointerId; joystick.setPointerCapture(event.pointerId); updateJoystick(event);
});
joystick.addEventListener("pointermove", event => { if (event.pointerId === activeJoystickPointer) updateJoystick(event); });
joystick.addEventListener("pointerup", event => { if (event.pointerId === activeJoystickPointer) resetJoystick(); });
joystick.addEventListener("pointercancel", resetJoystick);
joystick.addEventListener("lostpointercapture", resetJoystick);

function pollGamepad() {
  const pads = navigator.getGamepads?.() || [];
  let pad = null;
  for (const candidate of pads) { if (candidate) { pad = candidate; break; } }
  if (!pad) {
    input.padThrottle = 0; input.padSteer = 0; input.padPauseWasDown = false; return;
  }
  input.padSteer = Math.abs(pad.axes[0] || 0) > 0.16 ? pad.axes[0] : 0;
  const vertical = Math.abs(pad.axes[1] || 0) > 0.16 ? -(pad.axes[1] || 0) : 0;
  const rightTrigger = pad.buttons[7]?.value || 0;
  const leftTrigger = pad.buttons[6]?.value || 0;
  input.padThrottle = Math.abs(rightTrigger - leftTrigger) > 0.05 ? rightTrigger - leftTrigger : vertical;
  const pauseDown = Boolean(pad.buttons[9]?.pressed);
  if (pauseDown && !input.padPauseWasDown) setPaused(!state.paused);
  input.padPauseWasDown = pauseDown;
}

function update(dt) {
  pollGamepad();
  const throttle = clamp(input.keyThrottle + input.touchThrottle + input.padThrottle, -1, 1);
  const steer = clamp(input.keySteer + input.touchSteer + input.padSteer, -1, 1);
  const targetSpeed = throttle >= 0 ? throttle * CONFIG.topSpeed : throttle * CONFIG.topSpeed * 0.38;
  vehicle.speed = approach(vehicle.speed, targetSpeed, CONFIG.acceleration * dt);
  if (Math.abs(throttle) < 0.02) vehicle.speed = approach(vehicle.speed, 0, CONFIG.acceleration * 0.48 * dt);

  const speedFactor = clamp(Math.abs(vehicle.speed) / 5, 0.22, 1);
  const reverseSign = vehicle.speed < -0.05 ? -1 : 1;
  vehicle.yaw += steer * CONFIG.steeringRate * speedFactor * reverseSign * dt;
  vehicle.x += Math.sin(vehicle.yaw) * vehicle.speed * dt;
  vehicle.z += Math.cos(vehicle.yaw) * vehicle.speed * dt;

  const boundedX = clamp(vehicle.x, -CONFIG.worldHalfExtent, CONFIG.worldHalfExtent);
  const boundedZ = clamp(vehicle.z, -CONFIG.worldHalfExtent, CONFIG.worldHalfExtent);
  if (boundedX !== vehicle.x || boundedZ !== vehicle.z) vehicle.speed *= 0.25;
  vehicle.x = boundedX; vehicle.z = boundedZ;

  const forwardX = Math.sin(vehicle.yaw), forwardZ = Math.cos(vehicle.yaw);
  const desiredCamera = [vehicle.x - forwardX * 8.5, 5.2, vehicle.z - forwardZ * 8.5];
  const cameraAlpha = reducedMotion?.matches ? 1 : Math.min(1, 6 * dt);
  camera.x += (desiredCamera[0] - camera.x) * cameraAlpha;
  camera.y += (desiredCamera[1] - camera.y) * cameraAlpha;
  camera.z += (desiredCamera[2] - camera.z) * cameraAlpha;

  state.saveAccumulator += dt;
  if (state.saveAccumulator >= 2) { state.saveAccumulator = 0; saveNow(); }
}
"""#
}
