// Small progressive enhancements shared by every page.
(function () {
  // 0. Lucide icons: <i data-lucide="name"> -> inline SVG. Pages that render HTML later call window.refreshIcons().
  window.refreshIcons = () => { if (window.lucide) window.lucide.createIcons(); };
  window.refreshIcons();

  // Amenity icons for result cards: [{name, icon, note}] -> HTML (tooltips carry the name + note).
  const escHtml = (x) => String(x ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  window.amenityIcons = (list) => (list && list.length
    ? `<span class="amenity-icons">${list.map((a) => `<span class="am" title="${escHtml(a.name + (a.note ? `: ${a.note}` : ""))}" ` +
        `aria-label="${escHtml(a.name)}"><i data-lucide="${escHtml(a.icon)}"></i></span>`).join("")}</span>`
    : "");
  window.checkedAmenities = () =>
    [...document.querySelectorAll('.amenity-filter input[name=amenity]:checked')].map((i) => i.value).join(",");

  // Every Leaflet map in the app uses the same light basemap: standard OpenStreetMap tiles (free, no API
  // key), slightly desaturated in style.css (.base-tiles) so the teal/lime markers and route stand out.
  // (CARTO Positron was tried first, but its tiles now need an API key and come back watermarked.)
  window.addBaseTiles = (map) => L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19, className: "base-tiles",
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  }).addTo(map);
  // The lime map pin used for "this place" (listing being placed, start of route, ...).
  // A listing marker coloured by its live status (green / amber / red / grey), see live_status.js
  window.liveIcon = (live, faded = false) => L.divIcon({
    className: `live-pin ${live || "offline"}${faded ? " faded" : ""}`, html: "<span></span>",
    iconSize: [26, 36], iconAnchor: [13, 34], popupAnchor: [0, -30], tooltipAnchor: [0, -28] });
  // Marker clustering on every map with many markers (Leaflet.markercluster), or a plain layer if it didn't load
  window.markerLayer = (opts = {}) => (L.markerClusterGroup
    ? L.markerClusterGroup(Object.assign({ showCoverageOnHover: false, maxClusterRadius: 45, spiderfyOnMaxZoom: true,
        iconCreateFunction: (cl) => L.divIcon({ html: `<span>${cl.getChildCount()}</span>`, className: "cluster-icon",
                                                 iconSize: [36, 36] }) }, opts))
    : L.layerGroup());
  window.locationPin = (cls = "") => L.divIcon({ className: `map-pin ${cls}`, html: "<span></span>",
                                             iconSize: [30, 42], iconAnchor: [15, 40], tooltipAnchor: [0, -34] });

  // 1. Wide tables scroll sideways on small screens instead of squashing the page.
  document.querySelectorAll("main table").forEach((t) => {
    if (t.closest(".table-wrap")) return;
    const wrap = document.createElement("div");
    wrap.className = "table-wrap";
    t.parentNode.insertBefore(wrap, t);
    wrap.appendChild(t);
  });

  // 2. Notifications bell: "Mark as read" / "Mark all as read" update in place (fetch, JSON reply with the new
  //    unread count); without JavaScript the same forms post and redirect back.
  const notif = document.querySelector("details.notif");
  if (notif) {
    const count = notif.querySelector(".notif-count"), summaryText = notif.querySelector(".notif-summary");
    const all = notif.querySelector("form.notif-all");
    const setUnread = (n) => {
      count.textContent = n; count.hidden = !n;
      summaryText.textContent = n ? `${n} unread` : "all read";
      all.hidden = !n;
      notif.dataset.unread = n;
      notif.querySelector("summary").setAttribute("aria-label", `Notifications${n ? `, ${n} unread` : ""}`);
    };
    const post = async (form) => {
      const r = await fetch(form.action, { method: "POST", body: new FormData(form), credentials: "same-origin",
                                           headers: { "X-Requested-With": "fetch" } });
      if (!r.ok) throw new Error(r.status);
      return r.json();
    };
    const markRead = (item) => { item.classList.remove("unread"); item.querySelector("form.notif-one")?.remove(); };
    notif.querySelectorAll("form.notif-one").forEach((f) => f.addEventListener("submit", async (e) => {
      e.preventDefault();
      try { const d = await post(f); markRead(f.closest(".notif-item")); setUnread(d.unread); } catch { f.submit(); }
    }));
    all.addEventListener("submit", async (e) => {
      e.preventDefault();
      try { const d = await post(all); notif.querySelectorAll(".notif-item.unread").forEach(markRead); setUnread(d.unread); }
      catch { all.submit(); }
    });
    // × deletes one notification; "Clear all" deletes every one (after the confirm dialog in 2c)
    const clear = notif.querySelector("form.notif-clear"), list = notif.querySelector(".notif-list");
    const emptyCheck = (total) => {
      clear.hidden = !total;
      if (!total && !list.querySelector(".notif-empty")) {
        const p = document.createElement("p"); p.className = "muted notif-empty"; p.textContent = "No notifications.";
        list.prepend(p);
      }
    };
    notif.querySelectorAll("form.notif-del").forEach((f) => f.addEventListener("submit", async (e) => {
      e.preventDefault();
      try { const d = await post(f); f.closest(".notif-item").remove(); setUnread(d.unread); emptyCheck(d.total); }
      catch { f.submit(); }
    }));
    clear.addEventListener("submit", async (e) => {
      if (e.defaultPrevented) return;                     // the confirm dialog said no
      e.preventDefault();
      try { const d = await post(clear); notif.querySelectorAll(".notif-item").forEach((i) => i.remove()); setUnread(0); emptyCheck(0); }
      catch { clear.submit(); }
    });
  }

  // 2b. Modals (<dialog class="modal">): a button with data-open="<id>" opens one, data-close / Escape /
  //     a click on the backdrop closes it. Closing resets the form inside, so Cancel really cancels.
  document.addEventListener("click", (e) => {
    const opener = e.target.closest("[data-open]");
    if (opener) {
      const d = document.getElementById(opener.dataset.open);
      if (d && typeof d.showModal === "function") {
        d.showModal();
        d.querySelector(".modal-body input:not([type=hidden]), .modal-body select")?.focus();
      }
      return;
    }
    const closer = e.target.closest("[data-close]");
    if (closer && closer.closest("dialog")) closer.closest("dialog").close();
  });
  document.querySelectorAll("dialog.modal").forEach((d) => {
    d.addEventListener("click", (e) => { if (e.target === d) d.close(); });     // backdrop
    d.addEventListener("close", () => d.querySelectorAll("form").forEach((f) => f.reset()));
  });

  // Close the notifications dropdown / mobile menu when clicking elsewhere or pressing Escape.
  const toggle = document.getElementById("nav-toggle");
  document.addEventListener("click", (e) => {
    if (notif && notif.open && !notif.contains(e.target)) notif.open = false;
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (notif) notif.open = false;
    if (toggle) toggle.checked = false;
  });

  // 2c. Confirm dialogs: <form data-confirm="question"> or <button data-confirm="question"> (the button that was
  //     pressed wins; text in an attribute, so names with quotes are safe).
  document.addEventListener("submit", (e) => {
    const q = (e.submitter && e.submitter.dataset.confirm) || (e.target.dataset && e.target.dataset.confirm);
    if (q && !window.confirm(q)) { e.preventDefault(); e.stopImmediatePropagation(); }
  }, true);

  // 3. Prevent double submits: disable a form's buttons once it is submitted.
  document.addEventListener("submit", (e) => {
    const form = e.target;
    if (e.defaultPrevented || form.method.toLowerCase() !== "post") return;
    setTimeout(() => form.querySelectorAll("button").forEach((b) => { b.disabled = true; b.classList.add("busy"); }), 0);
  });

  // 4. Photo uploads: check type + size in the browser too (the server checks again).
  document.querySelectorAll('input[type=file][data-max-bytes]').forEach((input) => {
    input.addEventListener("change", () => {
      const max = Number(input.dataset.maxBytes), maxFiles = Number(input.dataset.maxFiles || 99);
      const ok = /^image\/(jpeg|png|webp)$/;
      const files = [...input.files];
      let msg = "";
      if (files.length > maxFiles) msg = `Choose at most ${maxFiles} photos at a time.`;
      const big = files.find((f) => f.size > max), bad = files.find((f) => !ok.test(f.type));
      if (!msg && bad) msg = `${bad.name}: only JPG, PNG or WebP images are allowed.`;
      if (!msg && big) msg = `${big.name} is larger than ${Math.round(max / 1048576)} MB.`;
      input.setCustomValidity(msg);
      if (msg) input.reportValidity();
    });
  });

  // 4b. Photo pickers: preview each chosen file, let the host pick what it shows, remove before upload.
  document.querySelectorAll(".photo-picker").forEach((picker) => {
    const input = picker.querySelector("input[type=file]"), list = picker.querySelector(".photo-previews");
    const fallback = picker.querySelector(".photo-default-type select");
    const canEdit = typeof DataTransfer === "function";
    picker.classList.add("js");                          // per-file selects replace the single "Shows" select
    let urls = [];
    const render = () => {
      urls.forEach(URL.revokeObjectURL);
      urls = [];
      list.innerHTML = "";
      const max = Number(input.dataset.maxBytes), ok = /^image\/(jpeg|png|webp)$/;
      [...input.files].forEach((f, i) => {
        const problem = !ok.test(f.type) ? "Not a JPG, PNG or WebP" : f.size > max ? `Larger than ${Math.round(max / 1048576)} MB` : "";
        const fig = document.createElement("figure");
        fig.className = "thumb" + (problem ? " bad-file" : "");
        const url = problem && !ok.test(f.type) ? "" : URL.createObjectURL(f);
        if (url) urls.push(url);
        fig.innerHTML = (url ? `<img alt="">` : `<div class="thumb-blank"><i data-lucide="file-x"></i></div>`) +
          `<figcaption><small class="fname"></small>${problem ? `<small class="bad">${problem}</small>` : ""}
             <select name="photo_type_each" aria-label="What this photo shows"></select></figcaption>` +
          (canEdit ? `<button type="button" class="thumb-del" aria-label="Remove this photo" title="Remove"><i data-lucide="x"></i></button>` : "");
        if (url) fig.querySelector("img").src = url;
        fig.querySelector(".fname").textContent = `${f.name} · ${(f.size / 1048576).toFixed(1)} MB`;
        const sel = fig.querySelector("select");
        sel.innerHTML = fallback.innerHTML;
        sel.value = /port|socket|plug|gun/i.test(f.name) ? "charging_port" : /park/i.test(f.name) ? "parking" : fallback.value;
        if (canEdit) fig.querySelector(".thumb-del").addEventListener("click", () => {
          const dt = new DataTransfer();
          [...input.files].forEach((g, j) => j !== i && dt.items.add(g));
          input.files = dt.files;
          input.dispatchEvent(new Event("change", { bubbles: true }));   // re-validate + re-render
        });
        list.appendChild(fig);
      });
      window.refreshIcons();
    };
    input.addEventListener("change", render);
  });

  // 5. Native validation messages: show them inline next to the field as well.
  document.addEventListener("invalid", (e) => {
    const el = e.target;
    el.classList.add("invalid");
    el.addEventListener("input", () => el.classList.remove("invalid"), { once: true });
  }, true);
})();

// Booking time rules, shared by the search page and the route planner (Flask and trg_booking_bi check them again):
// start in the future, end after start, 15 min - 12 h, inside the listing's opening hours ("HH:MM–HH:MM").
window.BookingRules = {
  openWindow(hours) {
    const [o, c] = hours.split("–").map((t) => { const [h, m] = t.split(":").map(Number); return h * 60 + m; });
    return (o === 0 && c >= 23 * 60 + 59) || o > c ? null : [o, c];
  },
  problem(hours, start, end, minMin = 15, maxMin = 720) {
    if (isNaN(start) || isNaN(end)) return "Choose a start and an end time.";
    const mins = Math.round((end - start) / 60000);
    if (start <= Date.now()) return "The start time must be in the future.";
    if (mins <= 0) return "The end time must be after the start time.";
    if (mins < minMin) return `A booking must be at least ${minMin} minutes.`;
    if (mins > maxMin) return `A booking can be at most ${maxMin / 60} hours.`;
    const win = hours ? this.openWindow(hours) : null;
    if (win) {
      const s = start.getHours() * 60 + start.getMinutes(), e = end.getHours() * 60 + end.getMinutes();
      if (start.toDateString() !== end.toDateString() || s < win[0] || e > win[1])
        return `Outside opening hours (${hours}). Choose a time inside them.`;
    }
    return "";
  },
};
