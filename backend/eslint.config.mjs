import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

// Lint gate for this package. Several rules are "warn" because the existing code has
// many hits (unused underscore-prefixed params, test doubles typed as any). Warnings still
// print on every run; errors fail the gate.
export default tseslint.config(
  {
    ignores: ["dist/**", "coverage/**", "node_modules/**"],
  },
  js.configs.recommended,
  tseslint.configs.recommended,
  {
    files: ["**/*.{js,mjs,cjs,ts,mts,cts}"],
    languageOptions: {
      globals: globals.node,
    },
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "warn",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-unsafe-function-type": "warn",
      "@typescript-eslint/no-unused-expressions": "warn",
      "no-irregular-whitespace": "warn",
      "prefer-const": "warn",
    },
  },
);
