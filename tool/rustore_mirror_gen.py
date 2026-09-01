# -*- coding: utf-8 -*-
"""Строит локальное Maven-зеркало ru.rustore.sdk из разрешённого дерева
Gradle (deps.txt, снятого офлайн из локального кэша) и .aar из кэша.

POM'ы синтезируются: у каждого модуля прямые зависимости = дети из
разрешённого дерева (первое полное вхождение), версии — уже разрешённые,
чтобы графу не требовалась conflict-resolution по метаданным, которых
больше негде взять. Версии, которые запрашиваются, но вытесняются
(например core:8.0.0 -> 10.3.0), получают тонкий POM с теми же
зависимостями: Gradle требует метаданные и для них.
"""
import json
import os
import sys

BS = chr(92)  # обратный слэш — heredoc в этой среде их «съедает»
deps_txt, repo_root, mirror_dir = sys.argv[1], sys.argv[2], sys.argv[3]
GROUP = "ru.rustore.sdk"

lines = open(deps_txt, encoding="utf-8").read().splitlines()
stack = []
deps = {}      # "g:a:sel" -> [ {g,a,sel} ]  (только полные вхождения)
versions = {}  # artifact -> set(versions requested or selected)
for ln in lines:
    body = ln.lstrip("| ")
    if not (body.startswith("+--- ") or body.startswith(BS + "--- ")):
        continue
    depth = (len(ln) - len(body)) // 5
    rest = body[5:]
    coord = rest.split(" ")[0]
    tail = rest[len(coord):]
    parts = coord.split(":")
    while stack and stack[-1][0] >= depth:
        stack.pop()
    if len(parts) < 2:  # "project :foo" и подобное — держим глубину, не зависимость
        stack.append((depth, None))
        continue
    g, a = parts[0], parts[1]
    req = parts[2] if len(parts) > 2 else None
    sel = tail.split("-> ")[1].split(" ")[0] if "-> " in tail else req
    constraint = "(c)" in tail
    full = "(*)" not in tail and not constraint
    key = "%s:%s:%s" % (g, a, sel)
    parent = stack[-1][1] if stack else None
    if parent in deps and not constraint:
        if not any(d["g"] == g and d["a"] == a for d in deps[parent]):
            deps[parent].append({"g": g, "a": a, "sel": sel})
    if g == GROUP and not constraint:
        versions.setdefault(a, set()).update(v for v in (req, sel) if v)
    if g == GROUP and full and key not in deps:
        deps[key] = []
    stack.append((depth, key if key in deps else None))

print("== прямые зависимости RuStore-модулей (из разрешённого дерева) ==")
for k in sorted(deps):
    print(" ", k.replace(GROUP + ":", ""), "->",
          ", ".join("%s:%s:%s" % (d["g"], d["a"], d["sel"]) for d in deps[k]) or "(none)")

# Какие версии каждого модуля выбраны (есть полное вхождение).
selected = {}
for k in deps:
    _, a, v = k.split(":")
    selected[a] = v

pom_tpl = """<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>{g}</groupId>
  <artifactId>{a}</artifactId>
  <version>{v}</version>
  <packaging>aar</packaging>
  <!-- Синтезировано из разрешённого дерева Gradle: артефакт RuStore SDK,
       оригинальный Artifactory (artifactory-external.vkpartner.ru) не
       отвечает. Зависимости зафиксированы на разрешённых версиях. -->
  <dependencies>
{deps}  </dependencies>
</project>
"""
dep_tpl = """    <dependency>
      <groupId>{g}</groupId>
      <artifactId>{a}</artifactId>
      <version>{v}</version>
      <scope>compile</scope>
    </dependency>
"""

written = []
missing_aar = []
for a, vs in sorted(versions.items()):
    sel = selected.get(a)
    dep_list = deps.get("%s:%s:%s" % (GROUP, a, sel), []) if sel else []
    for v in sorted(vs):
        d = os.path.join(mirror_dir, *GROUP.split("."), a, v)
        os.makedirs(d, exist_ok=True)
        body = "".join(dep_tpl.format(g=x["g"], a=x["a"], v=x["sel"]) for x in dep_list)
        with open(os.path.join(d, "%s-%s.pom" % (a, v)), "w", encoding="utf-8", newline="\n") as f:
            f.write(pom_tpl.format(g=GROUP, a=a, v=v, deps=body))
        written.append("%s:%s" % (a, v))
        if v == sel and not os.path.exists(os.path.join(d, "%s-%s.aar" % (a, v))):
            missing_aar.append("%s:%s" % (a, v))

print("== POM написаны:", len(written), "==")
print(" ", " ".join(written))
print("== выбранные версии без .aar в зеркале:", missing_aar or "нет", "==")

# Репозиторий-зеркало — первым в allprojects.repositories, только для группы.
gradle = os.path.join(repo_root, "android", "build.gradle")
src = open(gradle, encoding="utf-8").read()
marker = "allprojects {\n    repositories {\n"
block = (
    "allprojects {\n"
    "    repositories {\n"
    "        // RuStore SDK: свой Maven-репозиторий (artifactory-external.\n"
    "        // vkpartner.ru) 01.09.2026 перестал отвечать (404 даже на ping),\n"
    "        // а jitpack на эти координаты отвечает 401 — Gradle считает это\n"
    "        // жёсткой ошибкой, и релизная сборка падала. Зеркало лежит в\n"
    "        // репо (~5 МБ) и объявлено ПЕРВЫМ и только для этой группы:\n"
    "        // сборка перестаёт зависеть от чужого Artifactory.\n"
    "        maven {\n"
    "            url = uri(\"${rootDir}/rustore-maven\")\n"
    "            content { includeGroup(\"ru.rustore.sdk\") }\n"
    "        }\n"
)
assert src.count(marker) == 1, "allprojects.repositories marker not found"
if "rustore-maven" not in src:
    src = src.replace(marker, block, 1)
    open(gradle, "w", encoding="utf-8", newline="\n").write(src)
    print("== android/build.gradle: зеркало объявлено ==")
else:
    print("== android/build.gradle: зеркало уже объявлено ==")
