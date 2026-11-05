'use strict';
/**
 * 烹饪扩展内容：data/cooking/cooking-recipes.json
 *
 * 两件事：
 *  1) buildCookingContent() 给导出脚本用：把配方合并进 recipes，把成品餐食/食谱卷轴合并进 content_entities。
 *  2) syncCookingContent(db) 给服务端启动用：把这些实体补进运行时 sqlite（restoration_records +
 *     content_entities + items），否则 player_inventory 的外键会拒绝新物品。
 * 两步都幂等。
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE_FILE = path.join(ROOT, 'data', 'cooking', 'cooking-recipes.json');

function loadCookingSource() {
  if (!fs.existsSync(SOURCE_FILE)) return null;
  return JSON.parse(fs.readFileSync(SOURCE_FILE, 'utf8'));
}

function buildCookingContent() {
  const data = loadCookingSource();
  if (!data) return null;
  const recipes = [];
  const entities = [];
  for (const entry of data.recipes ?? []) {
    const suffix = String(entry.canonical_id).split('.').pop();
    const mealId = entry.result ?? `runtime.meal.cook.${suffix}`;
    const mealName = entry.meal?.display_name ?? entry.display_name;
    recipes.push({
      canonical_id: entry.canonical_id,
      source_canonical_id: entry.canonical_id,
      display_name: entry.display_name,
      port_city_canonical_id: entry.city,
      cargo: entry.cargo ?? {},
      silver_cost: Number(entry.silver_cost ?? 0),
      result_item_canonical_id: mealId,
      description: entry.meal?.tip ?? '',
      tier: Number(entry.tier ?? 1),
      required_cooking_level: Number(entry.required_level ?? 1),
    });
    entities.push({
      canonical_id: mealId,
      entity_category: 'item',
      catalog: 'mealItems',
      display_name: mealName,
      normalized_data: {
        catalog: 'mealItems', name: mealName, price: Number(entry.meal?.price ?? 800),
        buff: entry.meal?.buff ?? null, tip: entry.meal?.tip ?? null, cooking_tier: Number(entry.tier ?? 1),
      },
      price: Number(entry.meal?.price ?? 800),
    });
    const scrollId = `entity.item.recipe.cook.${suffix}`;
    const scrollName = entry.scroll?.display_name ?? `食谱：${entry.display_name}`;
    entities.push({
      canonical_id: scrollId,
      entity_category: 'item',
      catalog: 'recipeItems',
      display_name: scrollName,
      normalized_data: {
        catalog: 'recipeItems', name: scrollName, price: Number(entry.scroll?.price ?? 300),
        recipe_canonical_id: entry.canonical_id, tier: Number(entry.tier ?? 1),
        tip: entry.scroll?.source ?? '怪物或任务掉落',
      },
      price: Number(entry.scroll?.price ?? 300),
    });
  }
  return { recipes, entities, levelCurve: data.level_curve ?? { base: 60, growth: 1.25 } };
}

/** 把烹饪实体补进运行时库（幂等）。返回新增的实体数量。 */
function syncCookingContent(db) {
  const built = buildCookingContent();
  if (!built || !built.entities.length) return 0;
  const hasEntity = db.prepare('SELECT 1 AS ok FROM content_entities WHERE canonical_id=?');
  const nextEntityId = db.prepare('SELECT COALESCE(MAX(id),0)+1 AS id FROM content_entities');
  const nextItemId = db.prepare('SELECT COALESCE(MAX(id),0)+1 AS id FROM items');
  const insertRecord = db.prepare(`
    INSERT INTO restoration_records
      (canonical_id,record_origin,entity_kind,display_name,raw_value_json,normalized_value_json,
       restoration_status,confidence,originality_status,decision_reason,conflicts_json,runtime_selection,content_hash)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  const insertEntity = db.prepare(`
    INSERT INTO content_entities
      (id,canonical_id,source_record_id,source_canonical_id,entity_category,display_name,raw_data_json,normalized_data_json)
    VALUES (?,?,?,?,?,?,?,?)`);
  const insertItem = db.prepare('INSERT INTO items (id,content_entity_id,catalog,price) VALUES (?,?,?,?)');

  let added = 0;
  db.exec('BEGIN');
  try {
    for (const entity of built.entities) {
      if (hasEntity.get(entity.canonical_id)) continue;
      const recordCanonicalId = `record.cooking.${entity.canonical_id}`;
      const hash = crypto.createHash('sha256').update(entity.canonical_id).digest('hex');
      const record = insertRecord.run(
        recordCanonicalId, 'overlay', 'item', entity.display_name, '{}', '{}',
        'approved_overlay', null, 'derived', 'cooking expansion seed', '[]', 'approved_overlay', hash,
      );
      const entityId = nextEntityId.get().id;
      insertEntity.run(
        entityId, entity.canonical_id, Number(record.lastInsertRowid), entity.canonical_id,
        entity.entity_category, entity.display_name, '{}', JSON.stringify(entity.normalized_data),
      );
      insertItem.run(nextItemId.get().id, entityId, entity.catalog, Number(entity.price ?? 0));
      added += 1;
    }
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
  return added;
}

/** 纯函数：按怪物/任务等级挑一本还没学会的食谱（roll 供测试注入）。 */
function selectCookingDrop(recipes, learnedIds, level, roll = Math.random()) {
  const list = (recipes ?? []).filter((recipe) => typeof recipe.canonical_id === 'string' && recipe.canonical_id.startsWith('recipe.cook.'));
  if (!list.length) return null;
  const learned = new Set(learnedIds ?? []);
  const maxTier = Math.max(1, Math.min(5, 1 + Math.floor(Math.max(1, Number(level) || 1) / 12)));
  const eligible = list.filter((recipe) => Number(recipe.tier ?? 1) <= maxTier && !learned.has(recipe.canonical_id));
  if (!eligible.length) return null;
  // 优先掉当前等级段最高档的配方，避免高等级还在掉新手食谱
  const topTier = eligible.filter((recipe) => Number(recipe.tier ?? 1) === maxTier);
  const candidates = topTier.length ? topTier : eligible;
  const index = Math.min(candidates.length - 1, Math.max(0, Math.floor(Number(roll) * candidates.length)));
  return candidates[index];
}

module.exports = { buildCookingContent, syncCookingContent, loadCookingSource, selectCookingDrop, SOURCE_FILE };
