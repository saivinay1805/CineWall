const revealNodes = [...document.querySelectorAll("[data-reveal]")];

const revealObserver = new IntersectionObserver(
  entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      revealObserver.unobserve(entry.target);
    });
  },
  { threshold: 0.16 }
);

revealNodes.forEach((node, index) => {
  node.style.transitionDelay = `${Math.min(index * 45, 220)}ms`;
  revealObserver.observe(node);
});

const preview = document.querySelector("[data-parallax]");

if (preview) {
  const updateTilt = (x, y) => {
    preview.style.transform = `rotateX(${y}deg) rotateY(${x}deg) translateZ(0)`;
  };

  preview.addEventListener("pointermove", event => {
    const rect = preview.getBoundingClientRect();
    const offsetX = ((event.clientX - rect.left) / rect.width - 0.5) * 10;
    const offsetY = ((event.clientY - rect.top) / rect.height - 0.5) * -10;
    updateTilt(offsetX, offsetY);
  });

  preview.addEventListener("pointerleave", () => {
    updateTilt(0, 0);
  });
}
