const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

// Validate service account exists
const serviceAccountPath = path.join(__dirname, '..', 'config', 'serviceAccountKey.json');
if (!fs.existsSync(serviceAccountPath)) {
    console.error('CRITICAL: serviceAccountKey.json not found at', serviceAccountPath);
    console.error('Create Firebase project and download service account key first');
    process.exit(1);
}

const serviceAccount = require(serviceAccountPath);

// Initialize Firebase
admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function initializeFirestore() {
    console.log('Initializing Firestore with schema...');
    
    try {
        // Read schema
        const schemaPath = path.join(__dirname, '..', 'schema', 'firebase_schema.json');
        const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
        
        // Create collections if they don't exist
        for (const collectionName of Object.keys(schema.collections)) {
            console.log(`Ensuring collection exists: ${collectionName}`);
            
            // Try to create a dummy document to force collection creation
            const docRef = db.collection(collectionName).doc('_init');
            await docRef.set({
                _initialized