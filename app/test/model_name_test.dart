import 'package:cache/chat/model_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the quantisation in real file names', () {
    const cases = {
      'gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf': 'UD-Q2_K_XL',
      'gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf': 'UD-Q4_K_XL',
      'gemma-4-E2B-it-UD-IQ2_M.gguf': 'UD-IQ2_M',
      'gemma-4-E2B-it-UD-IQ3_XXS.gguf': 'UD-IQ3_XXS',
      'gemma-4-E2B-it-UD-Q3_K_XL.gguf': 'UD-Q3_K_XL',
      'gemma-4-E2B-it-IQ4_XS.gguf': 'IQ4_XS',
      'gemma-4-E2B-it-IQ4_NL.gguf': 'IQ4_NL',
      'gemma-4-E2B-it-Q3_K_S.gguf': 'Q3_K_S',
      'gemma-4-E2B-it-Q4_0.gguf': 'Q4_0',
      'gemma-4-E2B-it-Q4_K_M.gguf': 'Q4_K_M',
      'Qwen3-8B-Q4_K_M.gguf': 'Q4_K_M',
      'gemma-3-4b-it-q4_0.gguf': 'Q4_0',
      'llama-2-7b-chat.Q4_K_M.gguf': 'Q4_K_M',
      'Llama-3.2-3B-Instruct-Q8_0.gguf': 'Q8_0',
      'gemma-4-E2B-it-BF16.gguf': 'BF16',
      'Phi-3-mini-4k-instruct-fp16.gguf': 'F16',
      'gpt-oss-20b-MXFP4.gguf': 'MXFP4',
      '/models/sub/gemma-4-E4B-it-UD-Q8_K_XL.gguf': 'UD-Q8_K_XL',
    };
    cases.forEach((file, label) => expect(quantFromFileName(file), label, reason: file));
    expect(quantFromFileName('my-model.gguf'), isNull);
    expect(quantFromFileName('gemma-4-E2B-it.gguf'), isNull, reason: 'E2B, it and 4 are not quantisations');
  });

  test('the label comes from the metadata; the file name is used when the metadata has no file type', () {
    // general.file_type is in the file: llama.cpp names it, and that is the label.
    expect(prettyModelName('gemma4 E2B Q4_K - Medium', fileName: 'gemma-4-E2B-it-Q4_K_M.gguf'), 'Gemma 4 E2B · Q4_K_M');
    expect(prettyModelName('gemma4 E2B IQ2_M - 2.7 bpw', fileName: 'gemma-4-E2B-it-UD-IQ2_M.gguf'), 'Gemma 4 E2B · IQ2_M');
    // No general.file_type: llama.cpp guesses from the tensors and says so; the file's own label is used.
    expect(prettyModelName('gemma4 E2B Q4_0 (guessed)', fileName: 'gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf'), 'Gemma 4 E2B · UD-Q2_K_XL');
    expect(prettyModelName('gemma4 E2B Q4_0 (guessed)', fileName: 'my-model.gguf'), 'Gemma 4 E2B · Q4_0');
    expect(prettyModelName('gemma4 E2B', fileName: 'gemma-4-E2B-it-Q4_K_M.gguf'), 'Gemma 4 E2B · Q4_K_M');
  });

  test("llama.cpp's file type names that do not follow the pattern", () {
    expect(prettyModelName('gemma4 E2B Q2_K - Medium'), 'Gemma 4 E2B · Q2_K', reason: 'plain Q2_K, not Q2_K_M');
    expect(prettyModelName('gemma4 E2B Q2_K - Small'), 'Gemma 4 E2B · Q2_K_S');
    expect(prettyModelName('llama 8B IQ3_S mix - 3.66 bpw'), 'Llama 8B · IQ3_M');
    expect(prettyModelName('llama 8B IQ3_S - 3.4375 bpw'), 'Llama 8B · IQ3_S');
    expect(prettyModelName('gemma4 E2B TQ2_0 - 2.06 bpw ternary'), 'Gemma 4 E2B · TQ2_0');
    expect(prettyModelName('gpt-oss 20B MXFP4 MoE'), 'gpt-oss 20B · MXFP4_MOE');
    expect(prettyModelName('qwen3 8B Q6_K'), 'Qwen 3 8B · Q6_K');
  });
}
