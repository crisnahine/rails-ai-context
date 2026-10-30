// Every part of the page reads without this script, so each piece here only adds to markup that already works.

const doc = document.documentElement;
doc.classList.add("js");
const motion = !matchMedia("(prefers-reduced-motion: reduce)").matches;
const live = document.getElementById("announce");
const announce = (text) => {
  if (live === null) return;
  live.textContent = "";
  requestAnimationFrame(() => {
    live.textContent = text;
  });
};

const THEME_KEY = "rails-ai-context-theme";
const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const themeButton = document.querySelector(".theme");
const shownTheme = () => doc.dataset.theme ?? (darkQuery.matches ? "dark" : "light");
const otherTheme = () => (shownTheme() === "dark" ? "light" : "dark");
const labelTheme = () => themeButton.setAttribute("aria-label", `Switch to the ${otherTheme()} theme`);
if (themeButton !== null) {
  themeButton.addEventListener("click", () => {
    const next = otherTheme();
    doc.dataset.theme = next;
    try {
      localStorage.setItem(THEME_KEY, next);
    } catch {
      // Storage refused: the choice lasts this visit.
    }
    labelTheme();
    announce(`The ${next} theme is on.`);
  });
  darkQuery.addEventListener("change", labelTheme);
  labelTheme();
}

const menu = document.querySelector(".menu");
const navList = document.getElementById("nav-list");
if (menu !== null && navList !== null) {
  const setMenu = (open) => {
    menu.setAttribute("aria-expanded", String(open));
    navList.toggleAttribute("data-open", open);
  };
  menu.addEventListener("click", () => setMenu(menu.getAttribute("aria-expanded") !== "true"));
  navList.addEventListener("click", (event) => {
    if (event.target.closest("a")) setMenu(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menu.getAttribute("aria-expanded") === "true") {
      setMenu(false);
      menu.focus();
    }
  });
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // The clipboard API can be refused, on plain http or inside a frame, so the old way is the fallback.
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.cssText = "position:fixed;opacity:0;pointer-events:none";
    document.body.append(area);
    area.select();
    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    area.remove();
    return copied;
  }
}
for (const button of document.querySelectorAll(".copy")) {
  button.addEventListener("click", async () => {
    // A block that shows prompts carries the text to copy on its button.
    const text = button.dataset.copy ?? button.parentElement.querySelector("pre").textContent;
    const copied = await copyText(text.trim());
    button.textContent = copied ? "Copied" : "Copy failed";
    button.toggleAttribute("data-done", copied);
    announce(copied ? "Copied to the clipboard." : "The browser did not allow copying. Select the text instead.");
    setTimeout(() => {
      button.textContent = "Copy";
      button.removeAttribute("data-done");
    }, 1800);
  });
}

// Without script these are links to panels that all show; the roles are added here, where the tabs work.
for (const steps of document.querySelectorAll("[data-tabs]")) {
  const list = steps.querySelector(".step-list");
  const tabs = [...list.querySelectorAll("[data-tab]")];
  const panels = tabs.map((tab) => document.getElementById(tab.hash.slice(1)));
  list.setAttribute("role", "tablist");
  for (const [i, tab] of tabs.entries()) {
    tab.setAttribute("role", "tab");
    tab.id = `tab-${panels[i].id}`;
    tab.setAttribute("aria-controls", panels[i].id);
    panels[i].setAttribute("role", "tabpanel");
    panels[i].setAttribute("aria-labelledby", tab.id);
    panels[i].tabIndex = 0;
  }
  const select = (chosen, { focus = false, reveal = false } = {}) => {
    for (const [i, tab] of tabs.entries()) {
      const on = i === chosen;
      tab.setAttribute("aria-selected", String(on));
      tab.tabIndex = on ? 0 : -1;
      panels[i].hidden = !on;
    }
    if (focus) tabs[chosen].focus();
    if (reveal) tabs[chosen].scrollIntoView({ block: "nearest", inline: "nearest", behavior: motion ? "smooth" : "auto" });
  };
  list.addEventListener("click", (event) => {
    const tab = event.target.closest("[data-tab]");
    if (tab === null) return;
    event.preventDefault();
    select(tabs.indexOf(tab), { reveal: true });
  });
  list.addEventListener("keydown", (event) => {
    const at = tabs.indexOf(document.activeElement);
    if (at === -1) return;
    const to = { ArrowDown: at + 1, ArrowRight: at + 1, ArrowUp: at - 1, ArrowLeft: at - 1, Home: 0, End: tabs.length - 1, " ": at }[event.key];
    if (to === undefined) return;
    event.preventDefault();
    select((to + tabs.length) % tabs.length, { focus: true, reveal: true });
  });
  select(Math.max(0, tabs.findIndex((tab) => tab.hash === location.hash)));
}

const arriving = document.querySelectorAll(".reveal");
if (motion && "IntersectionObserver" in window) {
  const seen = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        seen.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.06 }
  );
  for (const element of arriving) seen.observe(element);
} else {
  for (const element of arriving) element.classList.add("in");
}

if (navList !== null && "IntersectionObserver" in window) {
  const sectionLinks = [...navList.querySelectorAll('a[href^="#"]')];
  // Kept as a set so the mark clears when no section is in the band, as on the hero.
  const inView = new Set();
  const current = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) inView.add(entry.target.id);
        else inView.delete(entry.target.id);
      }
      const shown = sectionLinks.find((link) => inView.has(link.hash.slice(1))) ?? null;
      for (const link of sectionLinks) link.setAttribute("aria-current", String(link === shown));
    },
    { rootMargin: "-45% 0px -50% 0px" }
  );
  for (const link of sectionLinks) {
    const section = document.getElementById(link.hash.slice(1));
    if (section !== null) current.observe(section);
  }
}
