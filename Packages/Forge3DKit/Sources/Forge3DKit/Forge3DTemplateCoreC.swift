import Foundation

extension Forge3DTemplate {
    static let scriptCoreC = #"""
function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, CONFIG.maxDPR);
  const width = Math.max(1, Math.round(canvas.clientWidth * dpr));
  const height = Math.max(1, Math.round(canvas.clientHeight * dpr));
  if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
  gl.viewport(0, 0, width, height);
}

function bindMesh(buffer) {
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.enableVertexAttribArray(aPosition);
  gl.vertexAttribPointer(aPosition, 3, gl.FLOAT, false, 0, 0);
}
function drawCube(viewProjection, x, y, z, yaw, sx, sy, sz, color) {
  bindMesh(cubeBuffer);
  const model = multiply(multiply(translation(x, y, z), rotationY(yaw)), scaling(sx, sy, sz));
  gl.uniformMatrix4fv(uMVP, false, multiply(viewProjection, model));
  gl.uniform4fv(uColor, color);
  gl.drawArrays(gl.TRIANGLES, 0, 36);
}
function drawGround(viewProjection) {
  bindMesh(groundBuffer);
  const size = CONFIG.worldHalfExtent;
  const model = scaling(size, 1, size);
  gl.uniformMatrix4fv(uMVP, false, multiply(viewProjection, model));
  gl.uniform4fv(uColor, [0.055, 0.09, 0.12, 1]);
  gl.drawArrays(gl.TRIANGLES, 0, 6);
}

function render() {
  resize();
  gl.enable(gl.DEPTH_TEST);
  gl.enable(gl.CULL_FACE);
  gl.clearColor(0.035, 0.055, 0.075, 1);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.useProgram(program);

  const aspect = Math.max(0.1, canvas.width / Math.max(1, canvas.height));
  const projection = perspective(CONFIG.fovDegrees * Math.PI / 180, aspect, 0.1, CONFIG.worldHalfExtent * 4);
  const forward = [Math.sin(vehicle.yaw), 0, Math.cos(vehicle.yaw)];
  const center = [vehicle.x + forward[0] * 3, 1.1, vehicle.z + forward[2] * 3];
  const view = lookAt([camera.x, camera.y, camera.z], center, [0,1,0]);
  const viewProjection = multiply(projection, view);

  drawGround(viewProjection);
  drawCube(viewProjection, vehicle.x, 0.75, vehicle.z, vehicle.yaw, 1.25, 0.65, 2.15, [0.84, 0.94, 1.0, 1]);
  drawCube(viewProjection, vehicle.x - Math.sin(vehicle.yaw) * 0.18, 1.38, vehicle.z - Math.cos(vehicle.yaw) * 0.18, vehicle.yaw, 0.82, 0.44, 1.05, [0.15, 0.48, 0.68, 1]);

  const markerCount = Math.min(CONFIG.maximumMarkers, 24);
  for (let i = 0; i < markerCount; i += 1) {
    const angle = i / markerCount * Math.PI * 2;
    const radius = CONFIG.worldHalfExtent * 0.72;
    drawCube(viewProjection, Math.sin(angle) * radius, 0.75, Math.cos(angle) * radius, angle, 0.34, 1.5, 0.34, [0.18, 0.28, 0.36, 1]);
  }
}

function frame(timestamp) {
  const seconds = timestamp / 1000;
  if (!state.lastTime) state.lastTime = seconds;
  const frameDelta = Math.min(CONFIG.maxFrameDelta, Math.max(0, seconds - state.lastTime));
  state.lastTime = seconds;
  if (!state.paused && !state.contextLost) {
    state.accumulator += frameDelta;
    while (state.accumulator >= CONFIG.step) { update(CONFIG.step); state.accumulator -= CONFIG.step; }
  }
  if (!state.contextLost) render();
  requestAnimationFrame(frame);
}

canvas.addEventListener("webglcontextlost", event => {
  event.preventDefault(); state.contextLost = true; setPaused(true); status.textContent = "Graphics paused — restoring";
});
canvas.addEventListener("webglcontextrestored", () => { saveNow(); location.reload(); });
document.addEventListener("visibilitychange", () => { if (document.hidden) { saveNow(); state.lastTime = 0; } });
window.addEventListener("pagehide", saveNow);

loadSave();
status.textContent = "Running 3D scene";
requestAnimationFrame(frame);
"""#
}
