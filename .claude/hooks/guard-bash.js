#!/usr/bin/env node
// PreToolUse(Bash) страж: детерминированно блокирует команды из категории
// «ноль исключений» — текстовые инструкции в CLAUDE.md совещательные, а эти
// правила критичны для целостности репо и прод-эталонов. Кроссплатформенный
// (node есть везде, где живёт этот репо, включая CI).
//
// Exit 2 = заблокировать вызов (stderr уходит Claude как причина).

let raw = "";
process.stdin.on("data", (chunk) => (raw += chunk));
process.stdin.on("end", () => {
  let command = "";
  try {
    command = String(JSON.parse(raw)?.tool_input?.command || "");
  } catch (_) {
    process.exit(0); // не наш формат — не мешаем
  }

  // Содержимое кавычек — данные (сообщения коммитов, echo-строки), а не флаги:
  // упоминание запретного паттерна в тексте не должно блокировать команду.
  // Реальные флаги в shell в кавычки не заворачивают.
  command = command
    .replace(/"(?:[^"\\]|\\.)*"/g, '""')
    .replace(/'[^']*'/g, "''");

  const rules = [
    {
      pattern: /--update-goldens/,
      reason:
        "«--update-goldens» локально запрещён: голден-эталоны генерируются в Linux-CI, " +
        "локальная регенерация на Windows отравит их шрифтовым диффом. " +
        "Регенерация — только workflow regen-tree-goldens.yml (gh workflow run).",
    },
    {
      pattern: /git\s+push[^&|;]*(\s--force\b|\s-f\b|\s--force-with-lease\b)/,
      reason:
        "Force-push запрещён правилами репо (push в main — это прод-деплой). " +
        "Если история сломана — обсуди с пользователем обычный revert.",
    },
    {
      pattern: /git\s+[^&|;]*--no-verify\b/,
      reason:
        "--no-verify запрещён: хуки не обходим. Если хук падает — чинить причину.",
    },
    {
      pattern: /git\s+commit[^&|;]*--amend\b/,
      reason:
        "amend запрещён (коммит мог уже уехать в прод через push-деплой). " +
        "Делай новый коммит поверх.",
    },
  ];

  for (const {pattern, reason} of rules) {
    if (pattern.test(command)) {
      process.stderr.write(`ЗАБЛОКИРОВАНО: ${reason}`);
      process.exit(2);
    }
  }
  process.exit(0);
});
