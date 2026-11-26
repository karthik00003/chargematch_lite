// Host "List my charger" (steps) + "Edit listing": the original ChargeMatch host.js location picker (pin, "Use my
// current location", address + city from the pin via Nominatim), its "Open 24 hours" switch and amenity notes, plus
// the Lite step switcher and charger list. Flask and MySQL check every value again when the form is submitted.
(function () {
  // ---------- listing location pickers
  // Pin = draggable lime marker. Lat/lng inputs are read-only and always follow the pin.
  // Address/City are filled by reverse geocoding (our /api/reverse proxy -> Nominatim),
  // but only when empty or still holding the previous auto-filled text, so manual edits are kept.
  const pickers = {};

  function initPickMap(div) {
    if (pickers[div.id]) return pickers[div.id];
    const form = document.querySelector(`form[data-map="${div.id}"]`);
    const msg = document.getElementById(`${div.id}-msg`);
    const f = (cls) => form.querySelector(cls);
    const lat = parseFloat(div.dataset.lat), lng = parseFloat(div.dataset.lng);
    const has = !isNaN(lat) && !isNaN(lng);
    const map = L.map(div).setView(has ? [lat, lng] : OP.center, has ? 16 : 13);
    addBaseTiles(map);
    // the host's other listings, for orientation; clicking one still places the pin there
    (OP.points || []).forEach(([la, ln, name]) => L.circleMarker([la, ln], { radius: 6, color: "#0b5560", weight: 2,
      fillColor: "#5fd4c4", fillOpacity: .9 }).addTo(map).bindTooltip(name).on("click", (e) => place(e.latlng)));
    let pin = null, geoSeq = 0;
    const say = (text, kind = "") => { msg.textContent = text; msg.className = `locate-msg small ${kind || "muted"}`; };
    const changed = (el) => el.dispatchEvent(new Event("input", { bubbles: true }));

    // Every time the host sets the pin (location button, map click, pin drag), Address and City are replaced by what
    // Nominatim finds there. Text the host types afterwards is kept until the pin moves again; a field edited while a
    // lookup is still running is not overwritten either.
    const addrFields = () => [["address", f(".f-address")], ["city", f(".f-city")]];
    async function fillAddress(ll, { onlyEmpty = false } = {}) {
      const seq = ++geoSeq;
      const atStart = new Map(addrFields().map(([, el]) => [el, el.value]));
      say("Finding address…");
      addrFields().forEach(([, el]) => { el.dataset.placeholder ??= el.placeholder; el.placeholder = "Finding address…"; });
      const restore = () => addrFields().forEach(([, el]) => { el.placeholder = el.dataset.placeholder || ""; });
      try {
        const r = await fetch(`${OP.reverse}?lat=${ll.lat.toFixed(6)}&lng=${ll.lng.toFixed(6)}`,
                              { headers: { Accept: "application/json" } });
        let data;
        try { data = await r.json(); } catch (e) { throw new Error(`the server answered HTTP ${r.status}`); }
        if (seq !== geoSeq) return;                       // the pin moved again meanwhile: that lookup wins
        restore();
        if (!r.ok) throw new Error(data.error || "lookup failed");
        const kept = [];
        addrFields().forEach(([k, el]) => {
          if (el.value !== atStart.get(el)) { kept.push(k); return; }     // typed during the lookup: keep it
          if (onlyEmpty && el.value.trim() && el.dataset.prefilled !== "1") return;   // page load: keep saved/typed text
          if (data[k]) {
            el.value = data[k];
            delete el.dataset.prefilled;
            changed(el);
          }
        });
        if (!data.address && !data.city) say("No address found at this spot — please type the address and city. Drag the pin to adjust.", "bad");
        else if (!data.address) say("No street address found at this spot — please type the address (city filled in). Drag the pin to adjust.", "bad");
        else if (!data.city) say("Address filled in from the map; no city found there — please type the city.", "bad");
        else say("Address and city filled in from the map — check them and edit if needed. Drag the pin to adjust.", "ok");
        if (kept.length) say(`${msg.textContent} (Your typed ${kept.join(" and ")} was kept.)`, msg.classList.contains("bad") ? "bad" : "ok");
      } catch (e) {
        if (seq === geoSeq) { restore(); say(`Couldn't find the address (${e.message}). Please type the address and city.`, "bad"); }
      }
    }

    function place(ll, { zoom = null, lookup = true } = {}) {
      ll = L.latLng(ll);
      if (!pin) {
        pin = L.marker(ll, { draggable: true, autoPan: true, icon: locationPin(), keyboard: true, title: "Listing location (drag to adjust)" }).addTo(map);
        pin.on("dragend", () => place(pin.getLatLng()));
      } else pin.setLatLng(ll);
      f(".f-lat").value = ll.lat.toFixed(6);
      f(".f-lng").value = ll.lng.toFixed(6);
      changed(f(".f-lat"));
      if (zoom) map.setView(ll, zoom); else if (!map.getBounds().pad(-0.1).contains(ll)) map.panTo(ll);
      if (lookup) fillAddress(ll);
    }
    // Page opened with a pin already set (edit page, or a form sent back with errors): fill Address / City once,
    // but only the ones that are still empty — saved or typed text is never replaced until the pin moves.
    if (has) {
      place([lat, lng], { lookup: false });
      if (!f(".f-address").value.trim() || !f(".f-city").value.trim()) fillAddress(L.latLng(lat, lng), { onlyEmpty: true });
    }
    map.on("click", (e) => place(e.latlng));

    function locate() {
      if (!navigator.geolocation || !window.isSecureContext) {
        say("Your browser can't share its location on this connection (it needs https). Click the map to place the pin instead.", "bad");
        return;
      }
      say("Asking your browser for your location…");
      navigator.geolocation.getCurrentPosition(
        (pos) => {
          const { latitude, longitude, accuracy } = pos.coords;
          place([latitude, longitude], { zoom: 17 });
          if (accuracy > 100) say(`Located to within ~${Math.round(accuracy)} m. Drag the pin to the exact spot.`, "ok");
        },
        (err) => say(err.code === err.PERMISSION_DENIED
            ? "Location permission was denied. Click on the map to place the listing instead (then drag the pin to adjust)."
            : err.code === err.TIMEOUT ? "Finding your location took too long. Try again, or click the map to place the pin."
            : "Your location isn't available right now. Click the map to place the pin instead.", "bad"),
        { enableHighAccuracy: true, timeout: 15000, maximumAge: 30000 });
    }
    return (pickers[div.id] = { map, locate, place, hasPin: () => !!pin, pin: () => pin });
  }

  document.querySelectorAll(".pick-map").forEach((div) => {
    const ready = () => initPickMap(div);
    const pane = div.closest(".wizard-pane");
    if (!pane || !pane.hidden) ready();
    document.querySelector(`.locate-btn[data-map="${div.id}"]`).addEventListener("click", () => ready().locate());
    // Home chargers are registered from home: on a new listing, ask for the current location right away.
    if (!pane && !div.dataset.lat && "autolocate" in div.dataset) ready().locate();   // the steps page does this in show(1)
    div.pickerReady = ready;
  });

  // ---------- opening hours: "Open 24 hours" switches the two dropdowns off (00:00–23:59 is saved)
  document.querySelectorAll(".f-24h").forEach((box) => {
    const form = box.closest("form");
    const sync = () => {
      form.querySelectorAll(".f-open, .f-close").forEach((sel) => { sel.disabled = box.checked; });
      if (window.FormCheck) window.FormCheck.check(form);
    };
    box.addEventListener("change", sync);
    sync();
  });

  // ---------- amenities: a note box is only active when its amenity is ticked
  document.querySelectorAll(".amenity-opt").forEach((opt) => {
    const box = opt.querySelector("input[type=checkbox]"), note = opt.querySelector("input[name^=note_]");
    box.addEventListener("change", () => {
      note.disabled = !box.checked;
      opt.classList.toggle("on", box.checked);
      if (box.checked) note.focus();
    });
  });

  // ---------- charger fields: connector first, then Power and Parking bay offer only what that connector allows
  // (each <option> carries its kW values and its bays). "Add charger" stays disabled until every value is valid.
  // Messages are short and fixed, and only appear after an attempt (Enter / Add / Update); each one goes away as
  // soon as its value is valid. Flask and MySQL (CHECK chk_charger_setup) check the same rules again.
  const fmtKw = (k) => (Number.isInteger(k) ? String(k) : k.toFixed(1));
  const C_PRICE_RE = /^\d{1,2}(\.\d{1,2})?$/;
  const C_LABEL_RE = /^[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*$/;
  const BAY_NAMES = { "2W": "Two-wheelers (2W)", "3W": "Autos (3W)", "4W": "Cars (4W)" };
  function chargerFields(box, { taken = () => [], button }) {
    const $ = (sel) => box.querySelector(sel);
    const E = { label: $(".f-label"), conn: $(".f-connector"), power: $(".f-power"), bay: $(".f-bay"), price: $(".f-price") };
    const ERR = { label: $(".f-label-err"), conn: $(".f-connector-err"), power: $(".f-power-err"), price: $(".f-price-err") };
    const powerHint = $(".f-power-hint"), bayHint = $(".f-bay-hint");
    const flagged = new Set();                     // fields whose message is showing (after an attempt)

    const chosen = () => {
      const o = E.conn.selectedOptions[0];
      if (!o || !o.value) return null;
      return { kw: JSON.parse(o.dataset.kw).map(Number), labels: JSON.parse(o.dataset.kwLabels),
               bays: JSON.parse(o.dataset.bays), name: o.textContent.trim(), code: o.dataset.code };
    };
    function problems() {
      const lv = E.label.value.trim(), pv = E.price.value.trim(), rs = Number(pv), c = chosen();
      return {
        label: !lv ? "Enter a label" : lv.length < 3 ? "Minimum 3 characters" : lv.length > 40 ? "Maximum 40 characters"
             : !C_LABEL_RE.test(lv) ? "Use letters, digits, spaces and - only"
             : taken().some((t) => t.toLowerCase() === lv.toLowerCase()) ? "This listing already has a charger with that label" : "",
        conn: c ? "" : "Choose a connector",
        power: !c ? "" : E.power.value === "" || !c.kw.includes(Number(E.power.value)) ? "Choose the power" : "",
        price: E.price.validity.badInput || !pv || !(rs >= 5 && rs <= 30) ? "Enter a price between ₹5 and ₹30"
             : !C_PRICE_RE.test(pv) ? "Use at most 2 decimals" : "",
      };
    }
    function check(attempt = false) {
      const msg = problems();
      const bad = Object.keys(msg).filter((k) => msg[k]);
      for (const k in ERR) {
        if (attempt && msg[k]) flagged.add(k);
        if (!msg[k]) flagged.delete(k);
        const shown = flagged.has(k) ? msg[k] : "";
        ERR[k].textContent = shown;
        E[k].closest("label").classList.toggle("has-error", !!shown);
        E[k].setAttribute("aria-invalid", shown ? "true" : "false");
      }
      if (button) {
        button.disabled = !!bad.length;
        button.title = bad.length ? "Fill in every charger value first" : "";
      }
      if (attempt && bad.length) E[bad[0]].focus();
      return !bad.length;
    }
    function sync(keepPower = E.power.value, keepBay = E.bay.value) {
      const c = chosen();
      E.power.disabled = E.bay.disabled = !c;
      if (!c) {
        E.power.innerHTML = E.bay.innerHTML = `<option value="">Choose the connector first</option>`;
        powerHint.textContent = bayHint.textContent = "";
      } else {
        E.power.innerHTML = (c.kw.length > 1 ? `<option value="">Choose the power…</option>` : "") +
          c.kw.map((k, i) => `<option value="${fmtKw(k)}">${c.labels[i]}</option>`).join("");
        if (keepPower !== "" && c.kw.includes(Number(keepPower))) E.power.value = fmtKw(Number(keepPower));
        powerHint.textContent = `${c.name}: ${c.kw.map(fmtKw).join(" / ")} kW`;
        E.bay.innerHTML = c.bays.slice().reverse().map((b) => `<option value="${b}">${BAY_NAMES[b]}</option>`).join("");
        E.bay.value = c.bays.includes(keepBay) ? keepBay : c.bays[c.bays.length - 1];
        bayHint.textContent = c.bays.length === 3 ? "Any vehicle size" : `${c.name}: ${c.bays.join(" or ")} bays only`;
      }
      check();
    }
    E.conn.addEventListener("change", () => sync("", E.bay.value));
    E.power.addEventListener("change", () => check());
    E.bay.addEventListener("change", () => check());
    E.label.addEventListener("input", () => check());
    E.price.addEventListener("input", () => check());
    const api = {
      E, check, sync,
      values() {
        const c = chosen();
        return { label: E.label.value.trim(), conn: E.conn.value, name: c ? c.name : "?",
                 power: E.power.value, bay: E.bay.value, price: Number(E.price.value.trim()).toFixed(2) };
      },
      load(v) {                                     // {label, conn, power, bay, price}
        E.label.value = v.label || ""; E.conn.value = v.conn || ""; E.price.value = v.price || "";
        flagged.clear();
        sync(v.power || "", v.bay || "");
      },
      clear() { api.load({}); },
      dirty: () => E.label.value.trim() !== "" || E.price.value !== "" || !!E.conn.value,
    };
    sync(E.power.dataset.value || "", E.bay.dataset.value || "");
    return api;
  }

  // "Add charger" on My chargers and the Edit charger page: real POST forms
  document.querySelectorAll("form[data-charger-form]").forEach((form) => {
    const labels = JSON.parse(form.dataset.labels || "[]");
    const btn = form.querySelector(".f-add");
    const cf = chargerFields(form, { taken: () => labels, button: btn });
    form.addEventListener("keydown", (e) => {     // Enter with a wrong value: say what is wrong
      if (e.key === "Enter" && e.target.tagName === "INPUT" && !cf.check(true)) e.preventDefault();
    });
    form.addEventListener("submit", (e) => { if (!cf.check(true)) e.preventDefault(); });
  });

  // =====================================================================================================
  // "List my charger": the steps switch inside the page; the whole form is submitted once at the end.
  // =====================================================================================================
  const wiz = document.getElementById("listing-wizard");
  if (!wiz) return;
  const panes = [...wiz.querySelectorAll(".wizard-pane")];
  const stepItems = [...document.querySelectorAll(".lite-steps li")];
  const mapDiv = document.getElementById("map-wiz");
  const field = (name) => wiz.elements[name];
  const named = (pane) => [...pane.querySelectorAll("input, select, textarea")]
    .filter((el) => el.name && el.type !== "hidden" && !el.disabled);
  const esc = (t) => String(t).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  let current = 1;
  const visited = new Set();                             // a step gets its tick only after the host has been there

  // ---- charger list (step 3): the entry fields have no name; each added charger is a table row with hidden inputs
  const entry = document.getElementById("charger-entry");
  const tbody = wiz.querySelector(".wiz-chargers tbody"), table = wiz.querySelector(".wiz-chargers");
  const addBtn = entry.querySelector(".f-add"), cancelBtn = entry.querySelector(".f-cancel");
  const title = entry.querySelector(".editor-title span");
  let editing = null;                                    // the <tr> being edited, or null
  const rows = () => [...tbody.querySelectorAll("tr.wiz-charger")];
  const rowVal = (tr, k) => tr.querySelector(`input[name=c_${k}]`).value;
  const CF = chargerFields(entry, { button: addBtn,
    taken: () => rows().filter((tr) => tr !== editing).map((tr) => rowVal(tr, "label")) });
  const checkEntry = (attempt = false) => CF.check(attempt);
  const entryDirty = () => !!editing || CF.dirty();
  function setMode(tr) {
    editing = tr;
    rows().forEach((r) => r.classList.toggle("editing-row", r === tr));
    entry.classList.toggle("editing", !!tr);
    addBtn.querySelector("span").textContent = tr ? "Update charger" : "Add charger";
    title.textContent = tr ? `Edit charger ${rowVal(tr, "label")}` : (rows().length ? "Add another charger" : "Add a charger");
    cancelBtn.hidden = !tr;
  }
  function clearEntry() { setMode(null); CF.clear(); }
  function rowHtml(c) {
    return `<td><b>${esc(c.label)}</b></td><td>${esc(c.name)}</td>
      <td class="num">${esc(c.power)}</td><td>${esc(c.bay)}</td><td class="num">${esc(c.price)}</td>
      <td class="row-actions"><button type="button" class="small secondary c-edit"><i data-lucide="pencil"></i>Edit</button>
        <button type="button" class="small ghost c-remove"><i data-lucide="trash-2"></i>Remove</button>
        <input type="hidden" name="c_label" value="${esc(c.label)}"><input type="hidden" name="c_connector" value="${esc(c.conn)}">
        <input type="hidden" name="c_power" value="${esc(c.power)}"><input type="hidden" name="c_bay" value="${esc(c.bay)}">
        <input type="hidden" name="c_price" value="${esc(c.price)}"></td>`;
  }
  function syncChargerList() {
    const n = rows().length;
    table.hidden = !n;
    wiz.querySelector(".wiz-no-chargers").hidden = !!n;
    if (!editing) title.textContent = n ? "Add another charger" : "Add a charger";
    markSteps();
  }
  function addCharger() {
    if (!checkEntry(true)) return false;
    const c = CF.values();
    let tr = editing;
    if (!tr) { tr = document.createElement("tr"); tr.className = "wiz-charger"; tbody.appendChild(tr); }
    tr.innerHTML = rowHtml(c);
    if (window.refreshIcons) window.refreshIcons();
    clearEntry();
    syncChargerList();
    CF.E.label.focus();
    return true;
  }
  tbody.addEventListener("click", (e) => {
    const tr = e.target.closest("tr");
    if (e.target.closest(".c-remove")) {
      if (tr === editing) clearEntry();
      tr.remove();
      syncChargerList();
    } else if (e.target.closest(".c-edit")) {
      setMode(tr);
      CF.load({ label: rowVal(tr, "label"), conn: rowVal(tr, "connector"),
                power: rowVal(tr, "power"), bay: rowVal(tr, "bay"), price: rowVal(tr, "price") });
      entry.scrollIntoView({ behavior: "smooth", block: "center" });
      CF.E.label.focus({ preventScroll: true });
    }
  });
  entry.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && e.target.tagName === "INPUT") { e.preventDefault(); addCharger(); }
  });
  addBtn.addEventListener("click", addCharger);
  cancelBtn.addEventListener("click", clearEntry);

  // ---- what each step still needs (used by Continue, the step marks and Submit)
  function paneProblems(n) {
    const pane = panes[n - 1];
    if (window.FormCheck) window.FormCheck.check(wiz);
    const bad = named(pane).filter((el) => !el.validity.valid).map((el) => el.dataset.label || el.name);
    if (n === 1 && !field("latitude").value) bad.unshift("location");
    if (n === 3 && !rows().length) bad.push("charger");
    return bad;
  }
  const MISSING = [[1, "Set the location, address and city (step 1)"], [2, "Enter a listing name of at least 3 characters (step 2)"],
                   [3, "Add at least one charger (step 3)"], [4, "Fix the amenity notes (step 4)"]];
  function markSteps() {
    const box = wiz.querySelector(".missing-msg");              // a Submit message goes once nothing is missing
    if (box && !box.hidden && !MISSING.some(([n]) => paneProblems(n).length)) box.hidden = true;
    stepItems.forEach((li) => {
      const n = Number(li.dataset.step);
      li.classList.toggle("current", n === current);
      li.querySelector("a").toggleAttribute("aria-current", n === current);
      const done = n !== current && visited.has(n) && !paneProblems(n).length;
      li.classList.toggle("done", done);
      li.querySelector(".ws-num").innerHTML = done && n !== current ? '<i data-lucide="check"></i>' : String(n);
    });
    if (window.refreshIcons) window.refreshIcons();
  }
  function touchPane(n) {                               // a Continue / Submit attempt: show this step's messages
    if (window.FormCheck) window.FormCheck.check(panes[n - 1], true);
  }

  // ---- switching steps
  function show(n, { scroll = true } = {}) {
    visited.add(current);
    current = Math.min(Math.max(1, n), panes.length);
    panes.forEach((p, i) => { p.hidden = i !== current - 1; });
    if (current === 1) {
      const pk = mapDiv.pickerReady();
      pk.map.invalidateSize();
      if (!pk.hasPin() && "autolocate" in mapDiv.dataset && !mapDiv.dataset.asked) { mapDiv.dataset.asked = "1"; pk.locate(); }
    }
    markSteps();
    if (history.replaceState) history.replaceState(null, "", `#step-${current}`);
    if (scroll) document.querySelector(".wizard-steps").scrollIntoView({ behavior: "smooth", block: "start" });
  }
  // Continue: the fields of this step must be valid first (Back and the step list never block)
  const dlg = document.getElementById("unsaved-charger");
  let pendingStep = null;
  function go(target, fromNext) {
    if (fromNext && current === 3 && entryDirty()) {           // the original asks before dropping a filled-in charger
      pendingStep = target;
      const ok = checkEntry(true);
      dlg.querySelector("h2 span").textContent = editing ? `Update charger ${rowVal(editing, "label")} before continuing?`
                                                         : "Add this charger before continuing?";
      dlg.querySelector(".u-add span").textContent = editing ? "Update charger" : "Add charger";
      dlg.querySelector(".u-add").disabled = !ok;
      dlg.querySelector(".unsaved-msg").textContent = ok
        ? "The charger form still has values that aren't saved."
        : "The charger form has values that aren't saved, and some aren't valid yet: fix them (Keep editing) or discard them.";
      dlg.showModal();
      return;
    }
    if (fromNext && current !== 3) {
      const bad = paneProblems(current);
      if (bad.length) {
        touchPane(current);
        if (current === 1 && !field("latitude").value) {
          const msg = document.getElementById("map-wiz-msg");
          msg.textContent = "Set the listing's location: use “Use my current location” or click the map";
          msg.className = "locate-msg small bad";
        }
        const first = named(panes[current - 1]).find((el) => !el.validity.valid);
        if (first) first.focus();
        return;
      }
    }
    show(target);
  }
  dlg.querySelector(".u-add").addEventListener("click", () => { if (addCharger()) { dlg.close(); show(pendingStep); } });
  dlg.querySelector(".u-discard").addEventListener("click", () => { clearEntry(); dlg.close(); show(pendingStep); });
  dlg.querySelector(".u-stay").addEventListener("click", () => dlg.close());

  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-go]");
    if (!b || !(wiz.contains(b) || b.closest(".lite-steps"))) return;
    e.preventDefault();
    go(Number(b.dataset.go), b.classList.contains("w-next"));
  });
  // "Submit for approval" (end of step 4): everything is checked first. If something is missing, ONE short message
  // with a link to that step is shown and nothing is sent; otherwise the whole form is posted once.
  const missingBox = wiz.querySelector(".missing-msg");
  const missingNow = () => MISSING.filter(([n]) => paneProblems(n).length);
  wiz.addEventListener("submit", (e) => {
    const missing = missingNow();
    if (missing.length) {
      e.preventDefault();
      const [n, text] = missing[0];
      missingBox.querySelector(".missing-text").innerHTML =
        `${esc(text)} — <a href="#step-${n}" data-go="${n}">go to step ${n}</a>`;
      missingBox.hidden = false;
      touchPane(n);
      if (window.refreshIcons) window.refreshIcons();
    } else wiz.querySelector(".w-submit").disabled = true;      // no double submit
  });
  wiz.addEventListener("input", () => { if (!missingBox.hidden && !missingNow().length) missingBox.hidden = true; });

  const fromHash = /^#step-(\d)$/.exec(location.hash);
  const start = Number(wiz.dataset.start) > 1 ? Number(wiz.dataset.start) : (fromHash ? Number(fromHash[1]) : 1);
  if (Number(wiz.dataset.start) > 1 || wiz.querySelector(".field-error:not(:empty)")) touchPane(start);
  show(start, { scroll: false });
})();
