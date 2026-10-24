import { unlockedKey } from './session.js';

// Inactivity lock: unlockedKey() locks when the deadline has passed, so a tick is all that is needed.
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'safevault-lock') unlockedKey();
});
