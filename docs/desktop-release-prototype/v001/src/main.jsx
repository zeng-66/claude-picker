import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './shell/App.jsx';
import PrototypeNotes from './PrototypeNotes.jsx';

createRoot(document.getElementById('root')).render(<><App /><PrototypeNotes /></>);
