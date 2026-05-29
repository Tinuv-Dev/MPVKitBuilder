#!/usr/bin/env node
/**
 * 规格驱动任务 JSON 校验脚本
 *
 * 用法:
 *   node validate-spec-tasks.js                       # 默认校验同目录 spec-tasks.example.json
 *   node validate-spec-tasks.js spec-tasks.example.json
 *
 * 退出码: 0 = 全部通过；1 = 至少一项错误。
 *
 * 校验项 (error 阻塞):
 *   - 顶层 schema: {version, phases[]}
 *   - phase: {num:int, title:string, tasks:[]}；num 唯一
 *   - task: id/title/status/deps/details 类型与值域
 *   - 每个 task.details 必须包含 7 个固定 Section
 *   - status=done 时，「交付物」「任务总结」必须有非空 items
 *   - id 全局唯一
 *   - deps 指向存在的 id
 *   - 依赖图无环 (DFS)
 *   - 级联一致性: status=done 时所有 deps 必须 done
 *
 * 警告 (warn, 不阻塞):
 *   - 任务被孤立 (没有被其它任务依赖, 且自己也无前置)
 *   - 同一 phase 内 task id 重复出现 (上面已 error)
 */

'use strict';

const fs = require('fs');
const path = require('path');

const STATUS_VALUES = new Set(['planned', 'in-progress', 'done']);
const EXPECTED_VERSION = 2;
const REQUIRED_DETAIL_SECTIONS = ['事实', '基于事实的演绎推理', '验证', '证据缺口', '验收边界', '交付物', '任务总结'];
const DONE_REQUIRED_ITEM_SECTIONS = ['交付物', '任务总结'];

const errors = [];
const warns = [];

function err(scope, msg) { errors.push({ scope, msg }); }
function warn(scope, msg) { warns.push({ scope, msg }); }

function isPlainObject(v) {
  return v && typeof v === 'object' && !Array.isArray(v);
}

function validateTopLevel(data) {
  if (!isPlainObject(data)) { err('root', '顶层不是 object'); return false; }
  if (data.version !== EXPECTED_VERSION) warn('root', `version=${data.version}（期望 ${EXPECTED_VERSION}）`);
  if (!Array.isArray(data.phases)) { err('root', 'phases 字段不是数组'); return false; }
  return true;
}

function validatePhases(data) {
  const seenPhaseNums = new Map(); // num -> index
  data.phases.forEach((p, i) => {
    const scope = `phases[${i}]`;
    if (!isPlainObject(p)) { err(scope, 'phase 不是 object'); return; }
    if (!Number.isInteger(p.num)) err(scope, `num 必须是整数（实际: ${JSON.stringify(p.num)}）`);
    else if (seenPhaseNums.has(p.num)) err(scope, `phase num=${p.num} 与 phases[${seenPhaseNums.get(p.num)}] 重复`);
    else seenPhaseNums.set(p.num, i);
    if (typeof p.title !== 'string' || !p.title.trim()) err(scope, 'title 必须是非空字符串');
    if (!Array.isArray(p.tasks)) err(scope, 'tasks 必须是数组');
  });
}

function validateTasks(data) {
  const idToTask = Object.create(null);  // id -> { task, phaseNum }
  const dupIds = new Set();

  // Pass 1: collect ids, basic field checks
  data.phases.forEach((p, pi) => {
    if (!Array.isArray(p.tasks)) return;
    p.tasks.forEach((t, ti) => {
      const scope = `phases[${pi}].tasks[${ti}]` + (t && t.id ? ` (${t.id})` : '');
      if (!isPlainObject(t)) { err(scope, '不是 object'); return; }

      if (typeof t.id !== 'string' || !t.id.trim()) {
        err(scope, 'id 必须是非空字符串');
      } else if (idToTask[t.id]) {
        err(scope, `id "${t.id}" 与已有任务重复`);
        dupIds.add(t.id);
      } else {
        idToTask[t.id] = { task: t, phaseNum: p.num, phaseIdx: pi, taskIdx: ti };
      }

      if (typeof t.title !== 'string') err(scope, 'title 必须是字符串');
      if (typeof t.desc !== 'string') err(scope, 'desc 必须是字符串');

      if (!STATUS_VALUES.has(t.status)) {
        err(scope, `status="${t.status}" 不在 {planned, in-progress, done} 之内`);
      }

      if (!Array.isArray(t.deps)) {
        err(scope, 'deps 必须是数组');
      } else {
        t.deps.forEach((d, di) => {
          if (typeof d !== 'string') err(scope, `deps[${di}] 必须是字符串`);
        });
        if (new Set(t.deps).size !== t.deps.length) warn(scope, 'deps 内有重复 id');
        if (t.deps.includes(t.id)) err(scope, '任务不能依赖自己');
      }

      if (!Array.isArray(t.details)) {
        err(scope, 'details 必须是数组');
      } else {
        const sectionTitles = new Set();
        const sectionItems = Object.create(null);
        t.details.forEach((sec, si) => {
          const sScope = `${scope}.details[${si}]`;
          if (!isPlainObject(sec)) { err(sScope, '不是 object'); return; }
          if (typeof sec.title !== 'string') err(sScope, 'title 必须是字符串');
          else sectionTitles.add(sec.title.trim());
          if (!Array.isArray(sec.items)) err(sScope, 'items 必须是数组');
          else sec.items.forEach((it, ii) => {
            if (typeof it !== 'string') err(`${sScope}.items[${ii}]`, '必须是字符串');
          });
          if (typeof sec.title === 'string') {
            sectionItems[sec.title.trim()] = Array.isArray(sec.items) ? sec.items.map(String).map(s => s.trim()).filter(Boolean) : [];
          }
        });
        REQUIRED_DETAIL_SECTIONS.forEach(title => {
          if (!sectionTitles.has(title)) err(scope, `details 缺少必需 Section：「${title}」`);
        });
        if (t.status === 'done') {
          DONE_REQUIRED_ITEM_SECTIONS.forEach(title => {
            if (!sectionItems[title]?.length) err(scope, `status=done 时「${title}」必须至少有一条 item`);
          });
        }
      }
    });
  });

  return { idToTask, dupIds };
}

function validateDepsExistence(data, idToTask) {
  data.phases.forEach((p, pi) => {
    if (!Array.isArray(p.tasks)) return;
    p.tasks.forEach((t, ti) => {
      if (!Array.isArray(t.deps)) return;
      t.deps.forEach(d => {
        if (typeof d !== 'string') return;
        if (!idToTask[d]) {
          err(`task ${t.id || `phases[${pi}].tasks[${ti}]`}`, `依赖 "${d}" 指向不存在的任务`);
        }
      });
    });
  });
}

function findCycles(idToTask) {
  // 3-color DFS, 收集所有发现的环
  const WHITE = 0, GRAY = 1, BLACK = 2;
  const color = Object.create(null);
  const stack = [];
  const cycles = [];

  function dfs(id) {
    if (color[id] === BLACK) return;
    if (color[id] === GRAY) {
      // 找到回边: 切出 stack 中从该 id 开始的部分
      const k = stack.indexOf(id);
      if (k !== -1) cycles.push(stack.slice(k).concat(id));
      return;
    }
    color[id] = GRAY;
    stack.push(id);
    const t = idToTask[id] && idToTask[id].task;
    if (t && Array.isArray(t.deps)) {
      t.deps.forEach(d => {
        if (idToTask[d]) dfs(d);
      });
    }
    stack.pop();
    color[id] = BLACK;
  }

  Object.keys(idToTask).forEach(id => { if (color[id] !== BLACK) dfs(id); });
  return cycles;
}

function validateCycles(idToTask) {
  const cycles = findCycles(idToTask);
  // 去重 (按 sorted 之后的 join)
  const seen = new Set();
  cycles.forEach(c => {
    const key = [...c].sort().join('>');
    if (seen.has(key)) return;
    seen.add(key);
    err('cycle', c.join(' → '));
  });
}

function validateCascade(idToTask) {
  Object.values(idToTask).forEach(({ task: t }) => {
    if (t.status !== 'done' || !Array.isArray(t.deps)) return;
    const unmet = t.deps.filter(d => {
      const dep = idToTask[d];
      return dep && dep.task.status !== 'done';
    });
    if (unmet.length) {
      err(`task ${t.id}`, `status=done 但以下前置未完成: ${unmet.join(', ')}`);
    }
  });
}

function findIslands(idToTask) {
  // 警告: 没有任何依赖关系参与的任务 (deps 空 + 没人依赖)
  const usedAsDep = new Set();
  Object.values(idToTask).forEach(({ task: t }) => {
    if (Array.isArray(t.deps)) t.deps.forEach(d => usedAsDep.add(d));
  });
  Object.values(idToTask).forEach(({ task: t }) => {
    const hasDeps = Array.isArray(t.deps) && t.deps.length > 0;
    if (!hasDeps && !usedAsDep.has(t.id)) {
      warn(`task ${t.id}`, '孤立任务（无前置，且无人依赖它）');
    }
  });
}

function summary(file, idToTask) {
  const all = Object.values(idToTask).map(x => x.task);
  const byStatus = { planned: 0, 'in-progress': 0, done: 0 };
  let evidenceComplete = 0;
  all.forEach(t => {
    if (byStatus[t.status] != null) byStatus[t.status]++;
    const titles = new Set((t.details || []).map(sec => String(sec.title || '').trim()));
    const doneItemsOk = t.status !== 'done' || DONE_REQUIRED_ITEM_SECTIONS.every(title => {
      const sec = (t.details || []).find(item => String(item.title || '').trim() === title);
      return (sec?.items || []).map(String).map(s => s.trim()).filter(Boolean).length > 0;
    });
    if (REQUIRED_DETAIL_SECTIONS.every(title => titles.has(title)) && doneItemsOk) evidenceComplete++;
  });
  console.log('');
  console.log(`📄 ${file}`);
  console.log(`   任务总数: ${all.length}`);
  console.log(`   按状态:   done=${byStatus.done}  in-progress=${byStatus['in-progress']}  planned=${byStatus.planned}`);
  console.log(`   证据完整: ${evidenceComplete}/${all.length}`);
}

function printIssues(label, list) {
  if (!list.length) return;
  console.log('');
  console.log(`${label} (${list.length}):`);
  list.forEach(({ scope, msg }) => {
    console.log(`  · [${scope}] ${msg}`);
  });
}

// ===== main =====
function main() {
  const arg = process.argv[2];
  const file = arg
    ? path.resolve(process.cwd(), arg)
    : path.resolve(__dirname, 'spec-tasks.example.json');

  if (!fs.existsSync(file)) {
    console.error(`找不到文件: ${file}`);
    process.exit(2);
  }

  let raw, data;
  try { raw = fs.readFileSync(file, 'utf8'); }
  catch (e) { console.error('读取失败: ' + e.message); process.exit(2); }
  try { data = JSON.parse(raw); }
  catch (e) { console.error('JSON 解析失败: ' + e.message); process.exit(2); }

  if (!validateTopLevel(data)) {
    printIssues('❌ Errors', errors);
    process.exit(1);
  }
  validatePhases(data);
  const { idToTask } = validateTasks(data);
  validateDepsExistence(data, idToTask);
  validateCycles(idToTask);
  validateCascade(idToTask);
  findIslands(idToTask);

  summary(file, idToTask);
  printIssues('⚠ Warnings', warns);
  printIssues('❌ Errors', errors);

  if (errors.length) {
    console.log('');
    console.log(`❌ 校验失败：${errors.length} 个 error${warns.length ? `，${warns.length} 个 warning` : ''}`);
    process.exit(1);
  } else {
    console.log('');
    console.log(`✅ 校验通过${warns.length ? `（${warns.length} 个 warning）` : ''}`);
    process.exit(0);
  }
}

main();
