// Navbar scroll
const nav = document.getElementById('nav');
window.addEventListener('scroll', () => {
  nav.classList.toggle('scrolled', window.scrollY > 40);
}, { passive: true });

// Scroll reveal
const els = document.querySelectorAll('[data-reveal]');
const obs = new IntersectionObserver((entries) => {
  entries.forEach((e, i) => {
    if (e.isIntersecting) {
      const siblings = e.target.parentElement.querySelectorAll('[data-reveal]');
      let delay = 0;
      siblings.forEach((s, j) => { if (s === e.target) delay = j * 100; });
      setTimeout(() => e.target.classList.add('visible'), delay);
      obs.unobserve(e.target);
    }
  });
}, { threshold: 0.1, rootMargin: '0px 0px -30px 0px' });
els.forEach(el => obs.observe(el));

// FAQ
document.querySelectorAll('.faq-q').forEach(btn => {
  btn.addEventListener('click', () => {
    const item = btn.closest('.faq-item');
    const open = item.classList.contains('open');
    document.querySelectorAll('.faq-item.open').forEach(o => o.classList.remove('open'));
    if (!open) item.classList.add('open');
  });
});

// Smooth scroll
document.querySelectorAll('a[href^="#"]').forEach(a => {
  a.addEventListener('click', e => {
    const id = a.getAttribute('href');
    if (id === '#') return;
    const t = document.querySelector(id);
    if (t) {
      e.preventDefault();
      window.scrollTo({ top: t.offsetTop - 80, behavior: 'smooth' });
    }
  });
});

// V1 vs V2 Comparison Slider
const slider = document.getElementById('compareSlider');
if (slider) {
  const handle = document.getElementById('compareHandle');
  const newSide = slider.querySelector('.compare-new');
  let dragging = false;

  function updateSlider(x) {
    const rect = slider.getBoundingClientRect();
    let pct = ((x - rect.left) / rect.width) * 100;
    pct = Math.max(5, Math.min(95, pct));
    newSide.style.clipPath = `inset(0 0 0 ${pct}%)`;
    handle.style.left = pct + '%';
  }

  slider.addEventListener('mousedown', (e) => { dragging = true; updateSlider(e.clientX); });
  window.addEventListener('mousemove', (e) => { if (dragging) { e.preventDefault(); updateSlider(e.clientX); } });
  window.addEventListener('mouseup', () => { dragging = false; });

  slider.addEventListener('touchstart', (e) => { dragging = true; updateSlider(e.touches[0].clientX); }, { passive: true });
  window.addEventListener('touchmove', (e) => { if (dragging) updateSlider(e.touches[0].clientX); }, { passive: true });
  window.addEventListener('touchend', () => { dragging = false; });
}
