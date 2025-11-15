module libtorrent::merkle_tree;

import std::math;
import std::hash::sha256;
import std::collections::list;

/**
 * Merkle Tree Implementation for BEP 52 (BitTorrent v2)
 * ======================================================
 *
 * BEP 52 Merkle Tree Specification:
 * - Block size: 16 KiB (16384 bytes) - MERKLE_BLOCK_SIZE
 * - Hash function: SHA-256 (32-byte hashes)
 * - Tree structure: Binary tree, bottom-up construction
 * - Padding: Incomplete blocks padded with zeros to 16 KiB
 * - Odd nodes: Duplicate last node when building parent layer
 * - Root hash: "pieces root" field in v2 torrents
 *
 * Layer Indexing:
 * - Layer 0: Leaf hashes (block-level, 16 KiB per hash)
 * - Layer N: Parent layer N-1
 * - Layer tree_height: Root (single hash = pieces_root)
 *
 * Example: 64 KiB file (4 blocks)
 *   Layer 0: [H0, H1, H2, H3] - 4 block hashes
 *   Layer 1: [H01, H23] - H01 = hash(H0||H1), H23 = hash(H2||H3)
 *   Layer 2: [Root] - hash(H01||H23) = pieces_root
 */

// Constants
const uint MERKLE_BLOCK_SIZE = 16384;   // 16 KiB per block
const uint SHA256_HASH_SIZE = 32;       // SHA-256 hash size

// Type alias for nested List (required in C3 0.7.0+)
// Cannot use List{List{char[]}} directly, must use alias
alias HashList = List{char[]};

/**
 * MerkleTree - Binary Merkle tree for v2 piece verification
 */
struct MerkleTree {
    uint block_size;          // Always MERKLE_BLOCK_SIZE (16384)
    uint num_blocks;          // Number of 16 KiB blocks in file
    uint tree_height;         // Height of tree (log2(num_blocks))

    // Layers stored from bottom (leaves) to top (root)
    // layers[0] = leaf hashes (block level)
    // layers[tree_height] = root hash
    List{HashList} layers;    // Each layer is a List of 32-byte hashes

    uint selected_layer;      // Layer index that covers piece_length
    char[SHA256_HASH_SIZE] pieces_root;  // Root hash (top of tree)
}

/**
 * MerkleProof - Proof that a piece belongs to the Merkle tree
 *
 * Contains uncle hashes needed to reconstruct root from piece data.
 */
struct MerkleProof {
    uint piece_index;         // Which piece this proves
    char[SHA256_HASH_SIZE] pieces_root;  // Expected root hash
    uint base_layer;          // Layer to start verification from
    uint index;               // Index in base layer
    uint length;              // Number of hashes at base layer (blocks per piece)
    List{char[]} uncle_hashes; // Proof path (one hash per layer)
}

/**
 * Build Merkle tree from file data
 *
 * Algorithm:
 * 1. Split data into 16 KiB blocks (pad last block if needed)
 * 2. Hash each block → Layer 0
 * 3. Combine pairs: hash(left || right) → Layer 1
 * 4. If odd number of nodes, duplicate last node
 * 5. Repeat until single root hash
 *
 * @param data File data to build tree from
 * @return Merkle tree with all layers and root hash
 */
fn MerkleTree* build(char[] data) @public
{
    MerkleTree* tree = mem::new(MerkleTree);
    tree.block_size = MERKLE_BLOCK_SIZE;

    // Calculate number of blocks (round up for incomplete block)
    tree.num_blocks = (uint)((data.len + MERKLE_BLOCK_SIZE - 1) / MERKLE_BLOCK_SIZE);

    // Calculate tree height = ceil(log2(num_blocks))
    if (tree.num_blocks == 0) {
        tree.tree_height = 0;
    } else if (tree.num_blocks == 1) {
        tree.tree_height = 0;
    } else {
        tree.tree_height = (uint)math::ceil(math::log2((double)tree.num_blocks));
    }

    tree.layers.init(mem);

    // Layer 0: Hash all blocks (leaves)
    HashList layer0;
    layer0.init(mem);

    for (uint i = 0; i < tree.num_blocks; i++) {
        usz block_start = (usz)i * (usz)MERKLE_BLOCK_SIZE;

        // Check if this is an incomplete final block
        if (block_start + (usz)MERKLE_BLOCK_SIZE > data.len) {
            // Incomplete block - pad with zeros
            char[MERKLE_BLOCK_SIZE] padded_block;
            usz actual_size = data.len - block_start;

            // Copy actual data using slice (length syntax)
            char[] actual_data = data[block_start:actual_size];
            for (usz j = 0; j < actual_size; j++) {
                padded_block[j] = actual_data[j];
            }

            // Pad with zeros
            for (usz j = actual_size; j < MERKLE_BLOCK_SIZE; j++) {
                padded_block[j] = 0;
            }

            char[SHA256_HASH_SIZE] hash = sha256::hash(padded_block[..]);

            // CRITICAL: Must allocate on heap, not push local variable slice!
            char[] hash_copy = mem::new_array(char, SHA256_HASH_SIZE);
            for (usz j = 0; j < SHA256_HASH_SIZE; j++) {
                hash_copy[j] = hash[j];
            }
            layer0.push(hash_copy);
        } else {
            // Full block - use length syntax for slicing
            char[] block = data[block_start:MERKLE_BLOCK_SIZE];
            char[SHA256_HASH_SIZE] hash = sha256::hash(block);

            // CRITICAL: Must allocate on heap, not push local variable slice!
            char[] hash_copy = mem::new_array(char, SHA256_HASH_SIZE);
            for (usz j = 0; j < SHA256_HASH_SIZE; j++) {
                hash_copy[j] = hash[j];
            }
            layer0.push(hash_copy);
        }
    }

    tree.layers.push(layer0);

    // Build parent layers until root
    uint current_layer_idx = 0;
    while (tree.layers[current_layer_idx].len() > 1) {
        HashList current_layer = tree.layers[current_layer_idx];
        HashList parent_layer;
        parent_layer.init(mem);

        usz num_nodes = current_layer.len();

        // Combine pairs of hashes
        for (usz i = 0; i < num_nodes; i += 2) {
            char[] left = current_layer.get(i);

            char[] right;
            if (i + 1 < num_nodes) {
                right = current_layer.get(i + 1);
            } else {
                // Odd number of nodes - duplicate last
                right = left;
            }

            // Concatenate left || right
            char[SHA256_HASH_SIZE * 2] combined;
            for (uint j = 0; j < SHA256_HASH_SIZE; j++) {
                combined[j] = left[j];
                combined[SHA256_HASH_SIZE + j] = right[j];
            }

            // Hash combined
            char[SHA256_HASH_SIZE] parent_hash = sha256::hash(combined[..]);

            // CRITICAL: Must allocate on heap, not push local variable slice!
            char[] hash_copy = mem::new_array(char, SHA256_HASH_SIZE);
            for (usz j = 0; j < SHA256_HASH_SIZE; j++) {
                hash_copy[j] = parent_hash[j];
            }
            parent_layer.push(hash_copy);
        }

        tree.layers.push(parent_layer);
        current_layer_idx++;
    }

    // Extract root hash
    HashList root_layer = tree.layers[tree.layers.len() - 1];
    char[] root = root_layer.get(0);
    for (uint i = 0; i < SHA256_HASH_SIZE; i++) {
        tree.pieces_root[i] = root[i];
    }

    return tree;
}

/**
 * Select layer index where one hash covers exactly piece_length
 *
 * Formula:
 *   blocks_per_piece = piece_length / MERKLE_BLOCK_SIZE
 *   selected_layer = log2(blocks_per_piece)
 *
 * Example:
 *   piece_length = 256 KiB
 *   blocks_per_piece = 256 KiB / 16 KiB = 16
 *   selected_layer = log2(16) = 4
 *
 * @param piece_length Piece length in bytes
 * @return Layer index
 */
fn uint MerkleTree.select_layer(&self, uint piece_length) @public
{
    uint blocks_per_piece = piece_length / MERKLE_BLOCK_SIZE;

    if (blocks_per_piece <= 1) {
        return 0;  // Layer 0 (one hash per block)
    }

    // log2(blocks_per_piece)
    uint layer = 0;
    uint n = blocks_per_piece;
    while (n > 1) {
        n = n / 2;
        layer++;
    }

    return layer;
}

/**
 * Generate Merkle proof for a piece
 *
 * Proof contains uncle hashes needed to reconstruct root from piece data.
 *
 * Algorithm:
 * 1. Start at selected_layer with piece_index
 * 2. For each layer up to root:
 *    - If index is even: uncle is index+1
 *    - If index is odd: uncle is index-1
 *    - Add uncle hash to proof
 *    - Move to parent: parent_index = index / 2
 *
 * @param piece_index Index of piece to prove
 * @return Merkle proof with uncle hashes
 */
fn MerkleProof* MerkleTree.generate_proof(&self, uint piece_index) @public
{
    MerkleProof* proof = mem::new(MerkleProof);
    proof.piece_index = piece_index;

    // Copy root hash
    for (uint i = 0; i < SHA256_HASH_SIZE; i++) {
        proof.pieces_root[i] = self.pieces_root[i];
    }

    proof.base_layer = self.selected_layer;
    proof.index = piece_index;

    // Calculate length (number of blocks in piece)
    proof.length = 1;
    for (uint i = 0; i < self.selected_layer; i++) {
        proof.length *= 2;
    }

    proof.uncle_hashes.init(mem);

    // Collect uncle hashes from selected_layer to root
    uint current_index = piece_index;
    for (uint layer_idx = self.selected_layer; layer_idx < self.tree_height; layer_idx++) {
        // Get layer using array indexing
        HashList* current_layer = &self.layers[layer_idx];

        // Find uncle (sibling)
        uint uncle_index;
        if (current_index % 2 == 0) {
            // Even index - uncle is to the right
            uncle_index = current_index + 1;
        } else {
            // Odd index - uncle is to the left
            uncle_index = current_index - 1;
        }

        // Check if uncle exists (may not if odd number of nodes)
        if (uncle_index < current_layer.len()) {
            char[] uncle = (*current_layer)[uncle_index];
            proof.uncle_hashes.push(uncle);
        } else if (current_index < current_layer.len()) {
            // No uncle - duplicate current node
            char[] current_hash = (*current_layer)[current_index];
            proof.uncle_hashes.push(current_hash);
        }

        // Move to parent
        current_index = current_index / 2;
    }

    return proof;
}

/**
 * Verify Merkle proof
 *
 * Algorithm:
 * 1. Hash the piece data (in 16 KiB blocks)
 * 2. Combine with uncle hashes layer by layer
 * 3. Compare final hash with pieces_root
 *
 * Uses temp allocator (@pool) for all intermediate hash allocations,
 * which are automatically freed when the function exits.
 *
 * @param piece_data Piece data to verify
 * @param proof Merkle proof with uncle hashes
 * @return True if proof is valid
 */
fn bool verify_proof(char[] piece_data, MerkleProof* proof) @public => @pool()
{
    // Calculate number of blocks in piece
    uint num_blocks = (uint)((piece_data.len + MERKLE_BLOCK_SIZE - 1) / MERKLE_BLOCK_SIZE);

    // Hash all blocks in piece (using temp allocator)
    List{char[]} block_hashes;
    block_hashes.init(tmem);

    for (uint i = 0; i < num_blocks; i++) {
        usz block_start = (usz)i * (usz)MERKLE_BLOCK_SIZE;

        // Check if this is an incomplete final block
        if (block_start + (usz)MERKLE_BLOCK_SIZE > piece_data.len) {
            // Incomplete block - pad with zeros
            char[MERKLE_BLOCK_SIZE] padded_block;
            usz actual_size = piece_data.len - block_start;

            // Copy actual data using slice (length syntax)
            char[] actual_data = piece_data[block_start:actual_size];
            for (usz j = 0; j < actual_size; j++) {
                padded_block[j] = actual_data[j];
            }
            for (usz j = actual_size; j < MERKLE_BLOCK_SIZE; j++) {
                padded_block[j] = 0;
            }

            char[SHA256_HASH_SIZE] hash = sha256::hash(padded_block[..]);

            // Allocate on temp allocator - auto-freed when function exits
            char[] hash_copy = mem::temp_array(char, SHA256_HASH_SIZE);
            for (usz j = 0; j < SHA256_HASH_SIZE; j++) {
                hash_copy[j] = hash[j];
            }
            block_hashes.push(hash_copy);
        } else {
            // Full block - use length syntax for slicing
            char[] block = piece_data[block_start:MERKLE_BLOCK_SIZE];
            char[SHA256_HASH_SIZE] hash = sha256::hash(block);

            // Allocate on temp allocator - auto-freed when function exits
            char[] hash_copy = mem::temp_array(char, SHA256_HASH_SIZE);
            for (usz j = 0; j < SHA256_HASH_SIZE; j++) {
                hash_copy[j] = hash[j];
            }
            block_hashes.push(hash_copy);
        }
    }

    // Build up from block hashes to base_layer
    List{char[]} current_hashes = block_hashes;
    uint current_layer = 0;

    while (current_layer < proof.base_layer) {
        List{char[]} parent_hashes;
        parent_hashes.init(tmem);

        for (usz i = 0; i < current_hashes.len(); i += 2) {
            char[] left = current_hashes.get(i);
            char[] right;

            if (i + 1 < current_hashes.len()) {
                right = current_hashes.get(i + 1);
            } else {
                right = left;  // Duplicate last
            }

            char[SHA256_HASH_SIZE * 2] combined;
            for (uint j = 0; j < SHA256_HASH_SIZE; j++) {
                combined[j] = left[j];
                combined[SHA256_HASH_SIZE + j] = right[j];
            }

            char[SHA256_HASH_SIZE] parent_hash = sha256::hash(combined[..]);

            // Allocate on temp allocator - auto-freed when function exits
            char[] hash_copy = mem::temp_array(char, SHA256_HASH_SIZE);
            for (usz j = 0; j < SHA256_HASH_SIZE; j++) {
                hash_copy[j] = parent_hash[j];
            }
            parent_hashes.push(hash_copy);
        }

        // With temp allocator, no need to manually free - will auto-free at function exit
        current_hashes = parent_hashes;
        current_layer++;
    }

    // Now combine with uncle hashes to reach root
    char[SHA256_HASH_SIZE] current_hash;
    for (uint i = 0; i < SHA256_HASH_SIZE; i++) {
        current_hash[i] = current_hashes.get(0)[i];
    }

    // No need to free - temp allocator will auto-free all allocations at function exit

    uint piece_index = proof.index;
    for (usz uncle_idx = 0; uncle_idx < proof.uncle_hashes.len(); uncle_idx++) {
        char[] uncle = proof.uncle_hashes.get(uncle_idx);

        char[SHA256_HASH_SIZE * 2] combined;
        if (piece_index % 2 == 0) {
            // Current is left, uncle is right
            for (uint i = 0; i < SHA256_HASH_SIZE; i++) {
                combined[i] = current_hash[i];
                combined[SHA256_HASH_SIZE + i] = uncle[i];
            }
        } else {
            // Uncle is left, current is right
            for (uint i = 0; i < SHA256_HASH_SIZE; i++) {
                combined[i] = uncle[i];
                combined[SHA256_HASH_SIZE + i] = current_hash[i];
            }
        }

        current_hash = sha256::hash(combined[..]);

        piece_index = piece_index / 2;
    }

    // Compare with pieces_root
    bool matches = true;
    for (uint i = 0; i < SHA256_HASH_SIZE; i++) {
        if (current_hash[i] != proof.pieces_root[i]) {
            matches = false;
        }
    }

    return matches;
}

/**
 * Free MerkleTree and all layers
 */
fn void MerkleTree.free(&self) @public
{
    // Free all layers
    for (usz i = 0; i < self.layers.len(); i++) {
        HashList* layer = &self.layers[i];
        // Free each hash array in the layer
        for (usz j = 0; j < layer.len(); j++) {
            char[] hash = (*layer)[j];
            free(hash);
        }
        layer.free();
    }
    self.layers.free();

    free(self);
}

/**
 * Free MerkleProof
 */
fn void MerkleProof.free(&self) @public
{
    // Note: uncle_hashes contains references to the tree's layers,
    // not heap-allocated copies. They're owned by the tree, not the proof.
    // So we only free the List itself, not the individual hashes.
    self.uncle_hashes.free();
    free(self);
}
