/* Square avatar cropper: one-finger drag, two-finger pinch, mouse and keyboard. */
class UniChatPhotoCropper {
  constructor(canvas, image) {
    this.canvas = canvas;
    this.image = image;
    this.width = image.naturalWidth || image.width;
    this.height = image.naturalHeight || image.height;
    this.baseScale = Math.max(canvas.width / this.width, canvas.height / this.height);
    this.zoom = 1;
    this.cx = this.width / 2;
    this.cy = this.height / 2;
    this.points = new Map();
    this.pinch = null;
    this.enabled = true;
    this.listeners = [];
    this.listen('pointerdown', e => this.down(e));
    this.listen('pointermove', e => this.move(e));
    this.listen('pointerup', e => this.up(e));
    this.listen('pointercancel', e => this.up(e));
    this.listen('lostpointercapture', e => this.up(e));
    this.listen('wheel', e => this.wheel(e), {passive: false});
    this.listen('keydown', e => this.key(e));
    this.paint();
  }
  listen(type, callback, options) {
    this.canvas.addEventListener(type, callback, options);
    this.listeners.push([type, callback, options]);
  }
  position(e) {
    const rect = this.canvas.getBoundingClientRect();
    return {x: (e.clientX - rect.left) * this.canvas.width / rect.width,
      y: (e.clientY - rect.top) * this.canvas.height / rect.height};
  }
  get scale() { return this.baseScale * this.zoom; }
  get offset() {
    return {x: this.canvas.width / 2 - this.cx * this.scale,
      y: this.canvas.height / 2 - this.cy * this.scale};
  }
  clamp() {
    const halfW = this.canvas.width / (2 * this.scale);
    const halfH = this.canvas.height / (2 * this.scale);
    this.cx = Math.max(halfW, Math.min(this.width - halfW, this.cx));
    this.cy = Math.max(halfH, Math.min(this.height - halfH, this.cy));
  }
  paint() {
    this.clamp();
    const offset = this.offset, context = this.canvas.getContext('2d');
    context.clearRect(0, 0, this.canvas.width, this.canvas.height);
    context.drawImage(this.image, offset.x, offset.y, this.width * this.scale, this.height * this.scale);
  }
  anchorZoom(zoom, point) {
    const before = this.offset;
    const ix = (point.x - before.x) / this.scale, iy = (point.y - before.y) / this.scale;
    this.zoom = Math.max(1, Math.min(4, zoom));
    this.cx = ix + (this.canvas.width / 2 - point.x) / this.scale;
    this.cy = iy + (this.canvas.height / 2 - point.y) / this.scale;
    this.paint();
  }
  startPinch() {
    this.pinch = null;
    if (this.points.size !== 2) return;
    const [a, b] = [...this.points.values()], offset = this.offset;
    const centre = {x: (a.x + b.x) / 2, y: (a.y + b.y) / 2};
    this.pinch = {distance: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), zoom: this.zoom,
      ix: (centre.x - offset.x) / this.scale, iy: (centre.y - offset.y) / this.scale};
  }
  down(e) {
    if (!this.enabled || this.points.size >= 2 || (e.pointerType === 'mouse' && e.button !== 0)) return;
    e.preventDefault();
    this.canvas.focus({preventScroll: true});
    this.points.set(e.pointerId, this.position(e));
    this.canvas.setPointerCapture(e.pointerId);
    this.canvas.classList.add('is-dragging');
    this.startPinch();
  }
  move(e) {
    if (!this.enabled || !this.points.has(e.pointerId)) return;
    e.preventDefault();
    const previous = this.points.get(e.pointerId), point = this.position(e);
    this.points.set(e.pointerId, point);
    if (this.points.size === 1) {
      this.cx -= (point.x - previous.x) / this.scale;
      this.cy -= (point.y - previous.y) / this.scale;
    } else {
      const [a, b] = [...this.points.values()], pinch = this.pinch;
      if (!pinch) { this.startPinch(); return; }
      this.zoom = Math.max(1, Math.min(4, pinch.zoom * Math.hypot(a.x - b.x, a.y - b.y) / pinch.distance));
      this.cx = pinch.ix + (this.canvas.width / 2 - (a.x + b.x) / 2) / this.scale;
      this.cy = pinch.iy + (this.canvas.height / 2 - (a.y + b.y) / 2) / this.scale;
    }
    this.paint();
  }
  up(e) {
    if (!this.points.has(e.pointerId)) return;
    this.points.delete(e.pointerId);
    try { if (this.canvas.hasPointerCapture(e.pointerId)) this.canvas.releasePointerCapture(e.pointerId); } catch {}
    this.startPinch();
    if (!this.points.size) this.canvas.classList.remove('is-dragging');
  }
  wheel(e) {
    if (!this.enabled) return;
    e.preventDefault();
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? this.canvas.height : 1;
    this.anchorZoom(this.zoom * Math.exp(-e.deltaY * unit * .0015), this.position(e));
    this.startPinch();
  }
  key(e) {
    if (!this.enabled) return;
    const direction = {ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]}[e.key];
    if (direction) {
      e.preventDefault();
      const step = e.shiftKey ? 40 : 10;
      this.cx -= direction[0] * step / this.scale;
      this.cy -= direction[1] * step / this.scale;
      this.paint();
    } else if (['+', '=', '-', '_'].includes(e.key)) {
      e.preventDefault();
      this.anchorZoom(this.zoom * (['+', '='].includes(e.key) ? 1.1 : 1 / 1.1),
        {x: this.canvas.width / 2, y: this.canvas.height / 2});
    } else if (e.key === '0' || e.key === 'Home') { e.preventDefault(); this.reset(); }
  }
  reset() {
    if (!this.enabled) return;
    this.zoom = 1; this.cx = this.width / 2; this.cy = this.height / 2;
    this.paint(); this.startPinch();
  }
  getCrop() {
    const side = Math.min(this.width, this.height) / this.zoom;
    return {zoom: this.zoom,
      x: this.width - side > 1e-8 ? (this.cx - side / 2) / (this.width - side) * 100 : 50,
      y: this.height - side > 1e-8 ? (this.cy - side / 2) / (this.height - side) * 100 : 50};
  }
  setEnabled(enabled) {
    this.enabled = enabled;
    if (!enabled) {
      for (const id of [...this.points.keys()]) this.up({pointerId: id});
    }
  }
  destroy() {
    this.setEnabled(false);
    for (const [type, callback, options] of this.listeners) this.canvas.removeEventListener(type, callback, options);
    this.listeners = [];
  }
}
