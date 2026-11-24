import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Runtime" / "X86_64AOTTranslator.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class AOTTranslatorAllocationHotPathTests(unittest.TestCase):
    def test_guest_input_is_borrowed_without_copying_to_a_byte_array(self):
        self.assertIn("guestCode.withUnsafeBytes { raw in", SOURCE)
        self.assertIn("UnsafeBufferPointer(", SOURCE)
        self.assertNotIn("[UInt8](guestCode.prefix", SOURCE)

    def test_translated_output_uses_one_word_buffer_and_one_final_data_copy(self):
        self.assertIn("var output = [UInt32]()", SOURCE)
        self.assertIn("machineCode: code.withUnsafeBytes { Data($0) }", SOURCE)
        self.assertNotIn("var output = [UInt8]()", SOURCE)

    def test_each_instruction_uses_a_fixed_four_word_emission_buffer(self):
        self.assertIn("private struct EncodedWords", SOURCE)
        self.assertIn("var words = EncodedWords()", SOURCE)
        self.assertNotIn("var words: [UInt32]", SOURCE)

    def test_lea_encoder_uses_fixed_word_buffer_without_dynamic_arrays(self):
        lea = section("case 0x8D:", "case 0xF3:")
        self.assertIn("addShiftedRegister", lea)
        self.assertIn("addImmediate", lea)
        self.assertNotIn("[UInt8]", lea)
        self.assertNotIn("[UInt32]", lea)
        self.assertNotIn("Data(", lea)
        self.assertNotIn("Array(", lea)

    def test_move_immediate_does_not_allocate_chunk_or_word_arrays(self):
        move = section("private static func moveImmediate(", "private static func moveWide(")
        self.assertNotIn("[UInt16]", move)
        self.assertNotIn("[UInt32]", move)
        self.assertIn("words.append(moveWide", move)

    def test_output_capacity_is_bounded_by_input_and_instruction_budgets(self):
        self.assertIn("min(bytes.count, 4096)", SOURCE)
        self.assertIn("min(maximumInstructions, 1024) * 4", SOURCE)
        self.assertIn("output.reserveCapacity(reserveWords)", SOURCE)

    def test_words_are_stored_in_little_endian(self):
        self.assertIn("output.append(word.littleEndian)", SOURCE)


if __name__ == "__main__":
    unittest.main()
