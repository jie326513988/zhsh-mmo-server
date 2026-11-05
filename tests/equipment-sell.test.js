'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { EquipmentRuntime } = require('../src/task-runtime/formal-gameplay');

function memStorage(state) {
  if (!state.gameplay_events) state.gameplay_events = {};
  return {
    transact(playerId, fn) { return fn(state); },
    getState() { return state; },
  };
}

function stateWithEquipment(id, quantity = 1) {
  return {
    player: { money: 100, level: 50, updated_at: null },
    inventory: quantity > 0 ? { [id]: quantity } : {},
    equipment: { accessories: [] },
  };
}

const catalog = {
  getEquipment(id) {
    return { canonical_id: id, display_name: '骨线外套', lj: 463, attributes: { lj: 463 } };
  },
};

test('equipment sell pays 20% of the source retail price and removes the item', () => {
  const state = stateWithEquipment('entity.equipment.test');
  const runtime = new EquipmentRuntime({ storage: memStorage(state), catalog });
  const result = runtime.sell('p1', 'entity.equipment.test', 'ev-sell');
  assert.equal(result.action, 'equipment_sold');
  assert.equal(result.unit_price, 92); // floor(463 * 0.2)
  assert.equal(state.player.money, 192);
  assert.equal(state.inventory['entity.equipment.test'], undefined);
});

test('equipment sell rejects items that are not in the backpack', () => {
  const state = stateWithEquipment('entity.equipment.test', 0);
  const runtime = new EquipmentRuntime({ storage: memStorage(state), catalog });
  assert.throws(() => runtime.sell('p1', 'entity.equipment.test', 'ev-sell'), /背包里没有这件装备/);
});
