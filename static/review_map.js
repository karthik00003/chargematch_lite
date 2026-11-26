// Small read-only maps with the listing pin (wizard review, admin dashboard cards, admin review page).
(function () {
  document.querySelectorAll(".review-map").forEach((div) => {
    const ll = [parseFloat(div.dataset.lat), parseFloat(div.dataset.lng)];
    const map = L.map(div, { scrollWheelZoom: false }).setView(ll, 17);
    addBaseTiles(map);
    L.marker(ll, { icon: locationPin(), keyboard: false }).addTo(map).bindTooltip(div.dataset.name);
  });
})();
