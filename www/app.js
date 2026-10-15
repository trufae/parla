(() => {
  document.documentElement.classList.add("has-js");

  const menuButton = document.querySelector(".menu-toggle");
  const navigation = document.querySelector("#navigation");
  menuButton.hidden = false;
  const closeMenu = () => {
    menuButton.setAttribute("aria-expanded", "false");
    navigation.classList.remove("open");
  };
  menuButton.addEventListener("click", () => {
    const open = menuButton.getAttribute("aria-expanded") !== "true";
    menuButton.setAttribute("aria-expanded", String(open));
    navigation.classList.toggle("open", open);
  });
  navigation.querySelectorAll("a").forEach((link) => link.addEventListener("click", closeMenu));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menuButton.getAttribute("aria-expanded") === "true") {
      closeMenu();
      menuButton.focus();
    }
  });

  const appearanceControl = document.querySelector(".appearance-control");
  const screenshot = document.querySelector("#desktop-screenshot");
  const screenshotLink = screenshot.closest("a");
  const appearances = {
    light: { src: "assets/screenshots/welcome.png", label: "light" },
    dark: { src: "assets/screenshots/welcome-dark.png", label: "dark" },
  };
  appearanceControl.hidden = false;
  document.querySelector(".no-js-light").hidden = true;
  appearanceControl.querySelectorAll("button").forEach((button) => {
    button.addEventListener("click", () => {
      const appearance = appearances[button.dataset.appearance];
      screenshot.src = appearance.src;
      screenshot.alt = `Parla in ${appearance.label} mode, with a chat sidebar and a welcome pane showing the Parla logo`;
      screenshotLink.href = appearance.src;
      screenshotLink.dataset.caption = `Parla’s native desktop interface in ${appearance.label} mode. Welcome screen from the project’s screenshot collection.`;
      appearanceControl.querySelectorAll("button").forEach((item) => {
        item.setAttribute("aria-pressed", String(item === button));
      });
    });
  });

  const lightbox = document.querySelector(".lightbox");
  if (typeof lightbox.showModal !== "function") return;
  const lightboxImage = lightbox.querySelector("img");
  const caption = lightbox.querySelector("p");
  document.querySelectorAll("[data-lightbox]").forEach((link) => {
    link.addEventListener("click", (event) => {
      // Preserve opening images in a new tab or window with modifier keys.
      if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      const image = link.querySelector("img");
      lightboxImage.src = link.href;
      lightboxImage.alt = image.alt;
      lightboxImage.width = image.naturalWidth;
      lightboxImage.height = image.naturalHeight;
      caption.textContent = link.dataset.caption;
      lightbox.showModal();
    });
  });
  lightbox.addEventListener("click", (event) => {
    if (event.target !== lightbox) return;
    const bounds = lightbox.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right ||
        event.clientY < bounds.top || event.clientY > bounds.bottom) lightbox.close();
  });
})();
