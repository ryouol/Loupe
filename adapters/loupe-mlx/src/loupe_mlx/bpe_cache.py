"""Opt-in immutable BPE vocabulary reuse for the pinned local experiment.

Call once after loading an immutable tokenizer. Rebuild this wrapper if the
vocabulary changes. Each generation still receives independent mutable state.
"""

from copy import copy
from importlib.metadata import version


def cache_bpe_vocabulary(tokenizer):
    from mlx_lm.tokenizer_utils import BPEStreamingDetokenizer, TokenizerWrapper

    if version("mlx-lm") != "0.31.3":
        raise ValueError("BPE vocabulary reuse has only been validated with mlx-lm 0.31.3")
    template = tokenizer.detokenizer
    if type(template) is not BPEStreamingDetokenizer:
        raise TypeError("BPE vocabulary reuse requires BPEStreamingDetokenizer")
    template.tokenmap = tuple(template.tokenmap)

    def fresh_detokenizer(_tokenizer):
        result = copy(template)
        result.reset()
        return result

    return TokenizerWrapper(
        tokenizer, detokenizer_class=fresh_detokenizer, eos_token_ids=tokenizer.eos_token_ids
    )
