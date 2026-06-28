allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
subprojects {
    val proj = this
    val configureAndroid = {
        if (proj.hasProperty("android")) {
            val android = proj.extensions.getByName("android") as com.android.build.gradle.BaseExtension
            android.compileSdkVersion(36)
        }
    }
    if (proj.state.executed) {
        configureAndroid()
    } else {
        proj.afterEvaluate {
            configureAndroid()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
