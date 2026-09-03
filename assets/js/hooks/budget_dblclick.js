// Pushes "begin_edit" when the user double-clicks a budget target amount.
// LiveView has no native dblclick binding, so this is a minimal hook.
export default {
  mounted() {
    this.el.addEventListener("dblclick", () => {
      this.pushEvent("begin_edit", {id: this.el.dataset.targetId});
    });
  },
};
