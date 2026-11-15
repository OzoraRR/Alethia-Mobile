package dev.alethia.mobile

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

@Composable
fun AlethiaLogo(
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
) {
    Image(
        painter = painterResource(R.drawable.alethia_logo),
        contentDescription = contentDescription,
        contentScale = ContentScale.Fit,
        modifier = modifier,
    )
}

@Preview(name = "Alethia logo · game badge", showBackground = true, backgroundColor = 0xFF050B14, widthDp = 220, heightDp = 220)
@Composable
fun AlethiaLogoPreview() {
    AlethiaTheme {
        AlethiaLogo(modifier = Modifier.size(180.dp))
    }
}
