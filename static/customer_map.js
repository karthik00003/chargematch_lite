// Find Chargers: browser geolocation -> /api/nearby -> Leaflet markers + result cards.
// From the original ChargeMatch customer_map.js, without the parts Lite doesn't have
// (30-second live-status polling, route planner, portable-charger hint, listing photos).
(function () {
  const $ = (id) => document.getElementById(id);
  const LABELS = { available: "Available", in_use: "In use" };   // out-of-service chargers are not in search at all
  const map = L.map("map").setView(CM.center, 12);
  addBaseTiles(map);

  const layer = markerLayer().addTo(map);           // clustered markers (app.js)
  const markers = {};            // listing_id -> Leaflet marker
  let here = null, youMarker = null, listings = [], seq = 0, circle = null;
  const km = () => Number($("radius").value);

  const pinIcon = (color) => L.divIcon({
    className: "pin", html: `<span class="dot ${color}"></span>`, iconSize: [18, 18], iconAnchor: [9, 9],
  });
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const fmtMins = (m) => (m == null ? "–" : m >= 60 ? `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}` : `${m} min`);

  function toLocalInput(d) {
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  function defaultStart() {
    const d = new Date(Date.now() + 30 * 60000);
    d.setMinutes(Math.ceil(d.getMinutes() / 15) * 15, 0, 0);
    return d;
  }
  // Same rules as trg_booking_bi (shared with app.js BookingRules): future start, 15 min – 12 h, inside opening hours.
  const bookingProblem = (st, start, end) => BookingRules.problem(st.hours, start, end, CM.minMin, CM.maxMin);

  function showVehicleSpec() {
    const opt = $("vehicle").selectedOptions[0];
    $("vehicle-spec").textContent = opt ? opt.dataset.spec : "";
  }

  function setHere(lat, lng, label) {
    here = { lat, lng };
    if (youMarker) youMarker.remove();
    youMarker = L.marker([lat, lng], { icon: pinIcon("blue"), zIndexOffset: 1000 }).addTo(map).bindPopup("Search point");
    $("loc-label").textContent = `${label}: ${lat.toFixed(5)}, ${lng.toFixed(5)}`;
    drawCircle();
    search();
  }

  function locate(auto) {
    if (!navigator.geolocation) {
      if (auto) setHere(CM.center[0], CM.center[1], "Default location (no GPS support)");
      return;
    }
    $("loc-label").textContent = "Getting your location…";
    navigator.geolocation.getCurrentPosition(
      (p) => setHere(p.coords.latitude, p.coords.longitude, `Your location (±${Math.round(p.coords.accuracy)} m)`),
      (err) => {
        const why = err.code === err.PERMISSION_DENIED ? "location permission denied" : "location unavailable";
        if (auto || !here) setHere(CM.center[0], CM.center[1], `Default location — Mangaluru (${why})`);
        else $("loc-label").textContent = `Couldn't get location: ${why}`;
      },
      { enableHighAccuracy: true, timeout: 10000, maximumAge: 60000 });
  }

  // ---------------------------------------------------------------- rendering
  function chargerRow(st, c) {
    const vehicle = $("vehicle").value;
    const spec = `${esc(c.connector)} · ${c.current_type} · <b>${c.power_kw} kW</b> · ${esc(c.bay)} bay · <b>₹${c.price}/kWh</b>`;
    const avail = `<span class="live-badge ${c.cstatus}">${LABELS[c.cstatus] || c.cstatus}</span>`;
    let detail = "";
    if (!vehicle) detail = `<span class="muted">Add a vehicle to check compatibility</span>`;
    else if (!c.compatible) detail = `<span class="bad">✗ ${esc(c.reason)}</span>`;
    else detail = `<span class="good">✓ Fits your vehicle</span>`;

    const div = document.createElement("div");
    div.className = "charger" + (c.compatible ? "" : " incompatible");
    div.innerHTML = `<div><b>${esc(c.label)}</b> ${avail}<br><small>${spec}</small><br>${detail}</div>`;
    if (vehicle && c.compatible) {
      const form = $("book-form").content.firstElementChild.cloneNode(true);
      form.charger_id.value = c.charger_id;
      form.vehicle_id.value = vehicle;
      const start = defaultStart();
      form.start_time.value = toLocalInput(start);
      form.end_time.value = toLocalInput(new Date(start.getTime() + 60 * 60000));       // 1 hour, editable
      form.start_time.min = form.end_time.min = toLocalInput(new Date());
      const out = form.querySelector(".duration"), err = form.querySelector(".book-error"), btn = form.querySelector(".book-btn");
      let lastLen = 60, tried = false;              // the message shows only after "Book" is pressed
      const update = () => {
        const s = new Date(form.start_time.value), e = new Date(form.end_time.value);
        const mins = Math.round((e - s) / 60000);
        out.textContent = !isNaN(mins) && mins > 0 ? fmtMins(mins) : "";
        const problem = bookingProblem(st, s, e);
        if (!problem) tried = false;
        err.textContent = tried ? problem : "";
        if (!problem) lastLen = mins;
        return problem;
      };
      form.start_time.addEventListener("input", () => {       // moving the start keeps the chosen length
        const s = new Date(form.start_time.value);
        if (!isNaN(s)) { form.end_time.value = toLocalInput(new Date(s.getTime() + lastLen * 60000)); form.end_time.min = form.start_time.value; }
        update();
      });
      form.end_time.addEventListener("input", update);
      update();
      form.addEventListener("submit", (e) => {
        tried = true;
        if (update()) { e.preventDefault(); e.stopImmediatePropagation(); return; }
        if (!confirm(`Book ${c.label} at ${st.name}\n${form.start_time.value.replace("T", " ")} → ` +
                     `${form.end_time.value.replace("T", " ")} (${out.textContent})\n₹${c.price}/kWh — you pay for the energy you take.`)) e.preventDefault();
      });
      div.appendChild(form);
    }
    return div;
  }

  function popupHtml(st) {
    return `<b>${esc(st.name)}</b><br>${st.distance_km} km away` +
      `<br>${esc(st.hours_label)}<br><a href="${esc(st.details_url)}">details</a>`;
  }

  // Radius: a slider (1-50 km) + quick buttons; the label, the circle on the map and the results follow it.
  function drawCircle() {
    if (!here) return;
    if (!circle) circle = L.circle([here.lat, here.lng], { radius: km() * 1000, color: "#c8dc00", weight: 2,
      fillColor: "#edff12", fillOpacity: 0.06, interactive: false }).addTo(map);
    circle.setLatLng([here.lat, here.lng]).setRadius(km() * 1000);
  }
  function showRadius() {
    const text = `Within ${km()} km`;
    $("radius-out").textContent = text;
    $("radius").setAttribute("aria-valuetext", text);
    $("radius").style.setProperty("--fill", `${((km() - 1) / 49) * 100}%`);
    document.querySelectorAll(".radius-quick .chip").forEach((b) => {
      const on = Number(b.dataset.km) === km();
      b.classList.toggle("on", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
    });
    drawCircle();
  }

  function render() {
    const out = $("results");
    out.innerHTML = "";
    [...listings].sort((a, b) => a.distance_km - b.distance_km).forEach((st) => {     // always nearest first
      const card = document.createElement("div");
      card.className = "card listing";
      card.id = `st-${st.listing_id}`;
      card.innerHTML = `<div class="listing-head">
          <div><h3 class="clickable">${esc(st.name)}
              <span class="pill ${st.open_now ? "available" : "offline"}">${st.open_now ? "Open now" : "Closed now"}</span></h3>
            <small class="muted">${esc(st.address)}, ${esc(st.city)} · ${esc(st.hours_label)} · Host: ${esc(st.host)}</small><br>
            ${window.amenityIcons(st.amenities)}
            <a class="details-link small" href="${esc(st.details_url)}">Details →</a></div>
          <div class="right"><span class="distance">${st.distance_km} km</span></div>
        </div>`;
      st.chargers.forEach((c) => card.appendChild(chargerRow(st, c)));
      card.querySelector("h3").addEventListener("click", () => {
        const m = markers[st.listing_id];
        if (layer.zoomToShowLayer) layer.zoomToShowLayer(m, () => m.openPopup());     // out of its cluster first
        else { map.setView([st.lat, st.lng], 15); m.openPopup(); }
        $("map").scrollIntoView({ behavior: "smooth", block: "center" });
      });
      out.appendChild(card);
    });
    window.refreshIcons && window.refreshIcons();
  }

  async function search() {
    if (!here) return;
    const params = new URLSearchParams({
      lat: here.lat, lng: here.lng, radius: $("radius").value,
      vehicle_id: $("vehicle").value || "",
      only_compatible: $("only_compatible").checked ? "1" : "0",
      amenities: window.checkedAmenities(),
    });
    const mine = ++seq;
    $("status").textContent = "Searching…";
    let res, data;
    try {
      res = await fetch(`${CM.api}?${params}`, { headers: { Accept: "application/json" } });
      data = await res.json();
    } catch (err) {
      if (mine !== seq) return;
      $("status").innerHTML = `<span class="bad">⚠️ Couldn't reach the server. Check your connection and try again.</span> ` +
        `<button type="button" class="small secondary" id="retry">Retry</button>`;
      $("retry").addEventListener("click", search);
      return;
    }
    if (mine !== seq) return;
    if (!res.ok) {
      $("status").innerHTML = `<span class="bad">⚠️ ${esc(data.error || "Search failed")}</span>`;
      return;
    }
    listings = data;

    layer.clearLayers();
    listings.forEach((st) => {
      // colour = live status of the listing's best charger; faded when nothing there fits this vehicle
      const m = L.marker([st.lat, st.lng], { icon: liveIcon(st.live, !st.any_compatible), title: st.name })
        .bindPopup(popupHtml(st));
      m.bindTooltip(`${st.name} · ${LABELS[st.live]}`);
      markers[st.listing_id] = m;
      layer.addLayer(m);
    });
    drawCircle();
    map.fitBounds(circle.getBounds(), { padding: [12, 12] });        // the whole search area is in view

    const usable = listings.filter((s) => s.any_compatible).length;
    $("status").innerHTML = listings.length
      ? `<b>${listings.length}</b> listing(s) within ${km()} km, nearest first · <b>${usable}</b> usable now for this vehicle`
      : `No ${$("only_compatible").checked ? "compatible " : ""}chargers within ${km()} km` +
        `${window.checkedAmenities() ? " with all the selected amenities" : ""}. ` +
        `Try a bigger radius, ${window.checkedAmenities() ? "fewer amenities, " : ""}untick “only chargers that fit”, or click the map to search elsewhere.`;
    render();
  }

  // ------------------------------------------------------------------ events
  $("locate").addEventListener("click", () => locate(false));
  map.on("click", (e) => setHere(e.latlng.lat, e.latlng.lng, "Picked on map"));
  $("vehicle").addEventListener("change", () => { showVehicleSpec(); search(); });
  $("only_compatible").addEventListener("change", search);
  document.querySelectorAll(".amenity-filter input").forEach((i) => i.addEventListener("change", search));
  let radiusTimer = null;
  $("radius").addEventListener("input", () => {
    showRadius();
    clearTimeout(radiusTimer);
    radiusTimer = setTimeout(search, 250);
  });
  document.querySelectorAll(".radius-quick .chip").forEach((b) => b.addEventListener("click", () => {
    $("radius").value = b.dataset.km;
    showRadius();
    clearTimeout(radiusTimer);
    search();
  }));

  showVehicleSpec();
  showRadius();
  locate(true);   // ask for GPS on page load; falls back to Mangaluru
})();
