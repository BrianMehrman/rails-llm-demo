// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// Scroll messages to bottom on page load and after turbo stream updates
function scrollMessages() {
  const el = document.getElementById("messages");
  if (el) el.scrollTop = el.scrollHeight;
}

document.addEventListener("turbo:load", scrollMessages);
document.addEventListener("turbo:before-stream-render", () => {
  setTimeout(scrollMessages, 50);
});

// Submit chat form on Enter; Shift+Enter inserts newline
document.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && e.target.matches(".chat-input textarea")) {
    e.preventDefault();
    e.target.closest("form").requestSubmit();
  }
});
