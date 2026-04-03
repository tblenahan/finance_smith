const path = require("path");
const colors = require("tailwindcss/colors");

module.exports = {
  darkMode: "class",
  content: [
    "./js/**/*.js",
    "../lib/finance_smith_web/**/*.ex",
    "../lib/finance_smith_web/**/*.heex",
    "../deps/petal_components/**/*.ex",
  ],
  theme: {
    extend: {
      colors: {
        primary: colors.blue,
        secondary: colors.violet,
        success: colors.green,
        danger: colors.red,
        warning: colors.amber,
        info: colors.sky,
      },
    },
  },
  plugins: [],
};
